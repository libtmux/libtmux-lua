local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local available, control = pcall(require, "libtmux._internal.control")
local M = {}

local function fixture(body, options)
    t.assertTrue(available, "observation control connection is missing")
    local driver, uv = drivers.new(), { pipes = {}, lines = {}, replies = {}, number = 1 }
    local rt = runtimes.new(driver, options)
    driver.uv = uv
    local bound = { token = {} }
    function bound:generation()
        return self.token
    end
    function bound.evidence()
        return { pid = "123", started = "100", version = "3.7c", socket = "/owned/socket" }
    end
    function bound._client(_, open, close)
        return rt:_operation(function(runtime, operation)
            local lease = assert(runtime:_resource(close))
            bound.lease = lease
            return open(
                runtime,
                { binary = "/tmux", socket = "/owned/pin", no_start = true },
                lease,
                operation
            )
        end)
    end
    function uv:reply(data)
        self.number = self.number + 1
        local tuple = "1 " .. self.number .. " 1"
        self.pipes[2].read(nil, "%begin " .. tuple .. "\n" .. data .. "%end " .. tuple .. "\n")
    end
    function uv.new_pipe()
        local pipe = {}
        uv.pipes[#uv.pipes + 1] = pipe
        function pipe:read_start(fn)
            self.read = fn
            return true
        end
        function pipe.write(_, data, done)
            uv.lines[#uv.lines + 1] = data
            local decoded = data:gsub("\\([0-7][0-7][0-7])", function(octal)
                return string.char(tonumber(octal, 8))
            end)
            driver.defer(function()
                done()
                local value
                if decoded:find("list-panes", 1, true) then
                    value = "LQ1\r$a;%0;@0;.\n"
                elseif decoded:find("display-message", 1, true) then
                    value = "LQ1\r$a;123;100;3.7c;/owned/socket;.\n"
                else
                    value = ""
                end
                if uv.hold then
                    uv.replies[#uv.replies + 1] = value
                else
                    uv:reply(value)
                end
            end)
            return true
        end
        function pipe:close(done)
            if self == uv.pipes[1] and not uv.ended then
                uv.ended = true
                driver.defer(function()
                    uv.pipes[2].read(nil, nil)
                    uv.pipes[3].read(nil, nil)
                    uv.exit(0, 0)
                end)
            end
            driver.defer(done)
        end
        return pipe
    end
    function uv.spawn(_, _, exited)
        uv.exit = exited
        local child = {}
        function child.close(_, done)
            driver.defer(done)
        end
        function child.kill()
            return true
        end
        driver.defer(function()
            uv.pipes[2].read(nil, "%begin 1 1 0\n%end 1 1 0\n%session-changed $0 fixture\n")
        end)
        return child, 123
    end
    local f = { runtime = rt, driver = driver, uv = uv, bound = bound }
    f.root = rt:start(function(runtime)
        f.connection = assert(control.open(runtime, bound, { session_id = "$0" }):await())
        return body(f)
    end)
    driver:drain()
    return f
end

function M.test_readiness_covers_requested_pane_and_bytes_arrive_without_process_slots()
    local f = fixture(function(state)
        local watch = assert(state.connection:watch_pane("%0"):await())
        state.driver.defer(function()
            state.uv.pipes[2].read(nil, "%output %0 raw\\000\\377\n")
        end)
        local event = assert(watch:next():await())
        t.assertEquals(event.kind, "output")
        t.assertEquals(event.pane, "%0")
        t.assertEquals(event.data, "raw\000\255")
        t.assertEquals(state.runtime:stats().active, 0)
        t.assertEquals(state.connection:coverage().panes, { "%0" })
        watch:close():await()
        t.assertNil(watch:next():await())
    end)
    local _, err = f.root:result()
    t.assertNil(err)
    t.assertTrue(f.root:is_retired())
    t.assertEquals(f.runtime:stats().resource_bytes, 0)
end

function M.test_cancelled_written_barrier_keeps_fifo_tombstone_for_next_caller()
    local f = fixture(function(state)
        state.uv.hold = true
        state.first = state.connection:watch_pane("%0")
        state.second = state.connection:watch_pane("%999")
        state.first:await()
    end)
    t.assertEquals(#f.uv.replies, 2)
    f.first:cancel()
    f.driver:drain()
    local _, cancelled = f.first:result()
    t.assertEquals(assert(cancelled).effect, "unknown")
    t.assertFalse(f.second:is_settled())
    f.uv:reply(table.remove(f.uv.replies, 1))
    f.driver:drain()
    t.assertFalse(f.second:is_settled())
    f.uv:reply(table.remove(f.uv.replies, 1))
    f.driver:drain()
    local _, err = f.second:result()
    t.assertEquals(assert(err).code, "uncovered_pane")
    t.assertTrue(f.root:is_retired())
end

function M.test_slow_watch_overflow_is_visible_and_does_not_block_other_watch()
    local f = fixture(function(state)
        local slow = assert(state.connection:watch_pane("%0", { max_bytes = 100 }):await())
        local fast = assert(state.connection:watch_pane("%0"):await())
        local pending = fast:next()
        state.driver.defer(function()
            state.uv.pipes[2].read(nil, "%output %0 " .. string.rep("x", 128) .. "\n")
        end)
        t.assertEquals(assert(pending:await()).data, string.rep("x", 128))
        local value, err = slow:next():await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "observation_gap")
        t.assertEquals(assert(err).partial.dropped_bytes, 128)
    end)
    local _, err = f.root:result()
    t.assertNil(err)
    t.assertTrue(f.root:is_retired())
end

function M.test_only_one_pending_next_and_cancellation_detaches_without_closing_watch()
    local f = fixture(function(state)
        local watch = assert(state.connection:watch_pane("%0"):await())
        local pending = watch:next()
        local value, err = watch:next():await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "concurrent_read")
        pending:cancel()
        state.driver.defer(function()
            state.uv.pipes[2].read(nil, "%extended-output %0 4 future : ok\n")
        end)
        local event = assert(watch:next():await())
        t.assertEquals(event.data, "ok")
        t.assertEquals(event.age, "4")
        t.assertEquals(event.metadata, "future")
    end)
    local _, err = f.root:result()
    t.assertNil(err)
    t.assertTrue(f.root:is_retired())
end

function M.test_live_opaque_results_keep_their_closed_state_after_collection()
    local function returned()
        local f = fixture(function(state)
            return {
                connection = state.connection,
                watch = assert(state.connection:watch_pane("%0"):await()),
            }
        end)
        return assert(f.root:result())
    end
    local value = returned()
    collectgarbage("collect")
    collectgarbage("collect")
    local coverage, err = value.connection:coverage()
    t.assertNil(coverage)
    t.assertEquals(assert(err).code, "observation_gap")
    t.assertTrue(value.connection:close():is_retired())
    t.assertEquals(type(value.watch.next), "function")
end

function M.test_protocol_failure_fails_pending_callers_and_retires_all_owned_bytes()
    local f = fixture(function(state)
        local watch = assert(state.connection:watch_pane("%0"):await())
        state.pending = watch:next()
        state.pending:await()
    end)
    f.uv.pipes[2].read(nil, "%end 99 99 99\n")
    f.driver:drain()
    local _, err = f.pending:result()
    t.assertEquals(assert(err).code, "protocol_error")
    t.assertTrue(f.root:is_retired())
    t.assertEquals(f.runtime:stats().resource_bytes, 0)
end

function M.test_typed_native_subscription_keeps_context_and_unregisters_on_close()
    local f = fixture(function(state)
        t.assertEquals(
            type(state.connection.subscribe_format),
            "function",
            "typed format subscription is missing"
        )
        local before = #state.uv.lines
        local invalid, err = state.connection:subscribe_format("%0", { "title;#{pid}" }):await()
        t.assertNil(invalid)
        t.assertEquals(assert(err).code, "unknown_field")
        t.assertEquals(#state.uv.lines, before)
        local watch = assert(state.connection:subscribe_format("%0", { "title", "dead" }):await())
        state.driver.defer(function()
            state.uv.pipes[2].read(
                nil,
                "%subscription-changed libtmux_1 $0 @0 0 %0 : LQ1\r$a;title\\;raw;0;.\n"
            )
        end)
        local event = assert(watch:next():await())
        t.assertEquals(event.kind, "format")
        t.assertEquals(event.pane, "%0")
        t.assertEquals(event.session_id, "$0")
        t.assertEquals(event.window_id, "@0")
        t.assertEquals(event.index, 0)
        t.assertEquals(event.value, { title = "title;raw", dead = false })
        before = #state.uv.lines
        assert(watch:close():await())
        t.assertEquals(#state.uv.lines, before + 1)
    end)
    local _, err = f.root:result()
    t.assertNil(err)
    t.assertTrue(f.root:is_retired())
end

function M.test_topology_change_invalidates_reported_coverage_until_a_new_barrier()
    local f = fixture(function(state)
        local watch = assert(state.connection:watch_pane("%0"):await())
        state.uv.pipes[2].read(nil, "%layout-change @0 new-layout old-layout *\n")
        local value, err = watch:next():await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "observation_gap")
        value, err = state.connection:coverage()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "observation_gap")
        assert(state.connection:watch_pane("%0"):await())
        t.assertTrue(state.connection:coverage().ready)
    end)
    local _, err = f.root:result()
    t.assertNil(err)
end

function M.test_queued_subscription_projection_is_charged_before_any_deferred_io()
    local f = fixture(function(state)
        local before = state.runtime:stats().resource_bytes
        local lines = #state.uv.lines
        local request = state.connection:subscribe_format("%0", { "title", "dead" })
        t.assertTrue(state.runtime:stats().resource_bytes > before)
        t.assertEquals(#state.uv.lines, lines)
        request:cancel()
    end)
    local _, err = f.root:result()
    t.assertNil(err)
    t.assertTrue(f.root:is_retired())
    t.assertEquals(f.runtime:stats().resource_bytes, 0)
end

function M.test_malformed_coverage_response_fails_the_connection_and_other_waiters()
    local f = fixture(function(state)
        local watch = assert(state.connection:watch_pane("%0"):await())
        state.uv.hold = true
        state.opening = state.connection:watch_pane("%0")
        state.pending = watch:next()
        state.pending:await()
    end)
    f.uv:reply("not an encoded metadata row\n")
    f.driver:drain()
    local _, err = f.pending:result()
    t.assertNotNil(err)
    t.assertEquals(assert(err).code, "protocol_error")
    t.assertTrue(f.root:is_retired())
    t.assertEquals(f.runtime:stats().resource_bytes, 0)
end

function M.test_parent_endpoint_lease_teardown_reports_a_gap_to_pending_watch()
    local f = fixture(function(state)
        local watch = assert(state.connection:watch_pane("%0"):await())
        state.pending = watch:next()
        state.pending:await()
    end)
    f.bound.lease:close()
    f.driver:drain()
    local value, err = f.pending:result()
    t.assertNil(value)
    t.assertNotNil(err)
    t.assertEquals(assert(err).code, "observation_gap")
    t.assertTrue(f.root:is_retired())
end

function M.test_subscription_cleanup_callback_overload_retires_removed_watch_waiter()
    local f = fixture(function(state)
        local watch = assert(state.connection:subscribe_format("%0", { "title" }):await())
        local other = assert(state.connection:watch_notifications():await())
        state.pending, state.other = watch:next(), other:next()
        state.pending:await()
        state.other:await()
    end, { max_callbacks = 1 })
    local completed = 0
    f.root:on_complete(function(_, err)
        t.assertNil(err)
        completed = completed + 1
    end)
    f.uv.pipes[2].read(nil, "%layout-change @0 ignored ignored *\n")
    f.driver:drain()
    local retired = f.pending:is_retired()
    local _, err = f.pending:result()
    local _, other_error = f.other:result()
    local stats = f.runtime:stats()
    if not retired then
        f.runtime:close()
        f.driver:drain()
    end
    t.assertTrue(retired, "removed format watch must retire its pending read")
    t.assertEquals(assert(err).code, "observation_gap")
    t.assertEquals(assert(other_error).code, "connection_lost")
    t.assertEquals(assert(other_error.cause).code, "queue_full")
    t.assertTrue(f.other:is_retired())
    t.assertTrue(f.root:is_retired())
    t.assertEquals(completed, 1)
    t.assertEquals(stats.logical, 0)
    t.assertEquals(stats.resources, 0)
    t.assertEquals(stats.callbacks, 0)
    t.assertEquals(stats.bytes, 0)
end

function M.test_unlinked_covered_window_reports_loss_but_unrelated_window_does_not()
    local f = fixture(function(state)
        local watch = assert(state.connection:watch_pane("%0"):await())
        state.pending = watch:next()
        state.pending:await()
        local _, err = state.connection:coverage()
        state.coverage_error = err
    end)
    f.uv.pipes[2].read(nil, "%unlinked-window-close @9\n")
    f.driver:drain()
    t.assertFalse(f.pending:is_settled())
    t.assertEquals(assert(f.connection:coverage()).panes, { "%0" })
    f.uv.pipes[2].read(nil, "%session-window-changed $0 @1\n%unlinked-window-close @0\n")
    f.driver:drain()
    local retired = f.pending:is_retired()
    local _, err = f.pending:result()
    if not retired then
        f.runtime:close()
        f.driver:drain()
    end
    t.assertTrue(retired, "unlinking a covered window must finish its pending pane read")
    t.assertEquals(assert(err).code, "observation_gap")
    t.assertEquals(assert(f.coverage_error).code, "observation_gap")
    t.assertTrue(f.root:is_retired())
    t.assertEquals(f.runtime:stats().bytes, 0)
end

return M
