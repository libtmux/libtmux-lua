local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local endpoints = require("libtmux._internal.endpoint")
local identity = require("libtmux._internal.identity")
local fields = require("libtmux._internal.fields")
local M = {}

local function fixture(body)
    local driver = drivers.new()
    local rt = runtimes.new(driver, { max_active = 1 })
    local state = { calls = {}, binds = 0 }
    local generation = assert(identity.generation({
        pid = "123",
        started = "456",
        socket = "/owned/socket",
        version = "3.7c",
    }))
    state.rows = {
        session = { { id = "$0", name = "one" } },
        window = { { id = "@0" }, { id = "@0" } },
        pane = { { id = "%0", window_id = "@0" } },
        window_link = { { session_id = "$0", window_id = "@0", index = 0 } },
        client = {},
        buffer = {},
    }
    local bound = {}
    function bound.generation()
        local evidence, err = identity.evidence(generation)
        if not evidence then
            return nil, err
        end
        return generation
    end
    function bound.evidence()
        return identity.evidence(generation)
    end
    function bound.close()
        state.closed = true
        identity.invalidate(generation)
        if state.lease then
            return state.lease:close()
        end
        return rt:_operation(function()
            return true
        end)
    end
    function bound.execute(_, argv)
        state.calls[#state.calls + 1] = argv
        return rt:_operation(function(_, operation)
            if state.before then
                state.before(#state.calls, argv)
            end
            if state.read_error then
                assert(operation:_retain(64))
                return nil, state.read_error
            end
            local format = argv[#argv]
            local kind = ({
                ["list-sessions"] = "session",
                ["list-panes"] = "pane",
                ["list-clients"] = "client",
                ["list-buffers"] = "buffer",
            })[argv[1]]
            kind = kind or (format:find("window_index", 1, true) and "window_link" or "window")
            local catalog = assert(fields.catalog(kind))
            local by_format = {}
            for name, field in pairs(catalog) do
                by_format[field.format] = { name, field }
            end
            local output = {}
            local rows = state.rows[kind]
            for _, value in ipairs(argv) do
                if value == "-f" and state.candidate_rows then
                    rows = state.candidate_rows
                end
            end
            for _, row in ipairs(rows) do
                output[#output + 1] = format:gsub("#{q:([^}]+)}", function(name)
                    local field = by_format[name]
                    local value = row[field[1]]
                    if value == nil then
                        value = field[2].type == "string" and "" or "0"
                    end
                    return tostring(value)
                end) .. "\n"
            end
            return { stdout = table.concat(output), stderr = "", exit_code = 0, signal = 0 }
        end)
    end
    local original = endpoints.bind
    rawset(endpoints, "bind", function(runtime, options)
        state.binds = state.binds + 1
        state.options = options
        local request = runtime:_operation(function()
            if state.resource then
                state.lease = assert(runtime:_resource(function(done)
                    state.closed = true
                    identity.invalidate(generation)
                    done()
                end))
            end
            return bound
        end)
        if state.cancel_delivery then
            request:_on_retire(function()
                state.connect_request:cancel()
            end)
        end
        return request
    end)
    local ok, err = pcall(function()
        local root = rt:start(function(runtime)
            return body(runtime, state)
        end)
        driver:drain()
        t.assertTrue(root:is_retired())
        local _, failure = root:result()
        t.assertNil(failure)
    end)
    rawset(endpoints, "bind", original)
    if not ok then
        error(err, 0)
    end
end

local function connect(rt)
    t.assertEquals(type(rt.connect), "function", "public connection is missing")
    return assert(rt:connect({ binary = "/bin/tmux", socket_path = "/owned/socket" }):await())
end

function M.test_connection_copies_options_and_invalid_snapshot_dispatches_nothing()
    fixture(function(rt, state)
        t.assertEquals(type(rt.connect), "function", "public connection is missing")
        local options = { binary = "/bin/tmux", socket_path = "/owned/socket" }
        local request = rt:connect(options)
        options.socket_path = "/other/socket"
        local server = assert(request:await())
        t.assertEquals(state.options.socket, "/owned/socket")
        local value, err = server:snapshot({ strict = "yes" }):await()
        t.assertNil(value)
        t.assertEquals(err.code, "invalid_options")
        t.assertEquals(#state.calls, 0)
        value, err = server:snapshot({ fields = { panes = { "unknown" } } }):await()
        t.assertNil(value)
        t.assertEquals(err.code, "unknown_field")
        t.assertEquals(#state.calls, 0)
        server:close():await()
        value, err = server:snapshot():await()
        t.assertNil(value)
        t.assertEquals(err.code, "closed")
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_strict_capture_has_one_verification_and_preserves_raw_duplicates()
    fixture(function(rt, state)
        local server = connect(rt)
        local snapshot = assert(server:snapshot({ strict = true }):await())
        t.assertTrue(snapshot.complete)
        t.assertEquals(snapshot.verification.passes, 1)
        t.assertEquals(#state.calls, 12)
        t.assertEquals(#snapshot.windows, 1)
        t.assertEquals(#snapshot.raw.windows, 2)
        t.assertEquals(snapshot.capabilities.version, "3.7c")
        t.assertTrue(snapshot.capabilities.fields.pane.dead_signal)
        t.assertTrue(#snapshot.projections.client > 0)
        t.assertEquals(#snapshot.panes:where({ id = "%0" }), 1)
        t.assertEquals(#state.calls, 12)
        server:close():await()
    end)
end

function M.test_strict_topology_change_returns_original_partial_without_retry()
    fixture(function(rt, state)
        local server = connect(rt)
        state.before = function(index)
            if index == 7 then
                state.rows.buffer = { { name = "arrived" } }
            end
        end
        local snapshot, err = server:snapshot({ strict = true }):await()
        t.assertNil(snapshot)
        t.assertEquals(err.code, "inconsistent_snapshot")
        t.assertEquals(#state.calls, 12)
        t.assertEquals(#err.partial.buffers, 0)
        t.assertFalse(err.partial.complete)
        t.assertEquals(err.partial.races[#err.partial.races].code, "topology_changed")
        server:close():await()
    end)
end

function M.test_empty_daemon_keeps_buffers_and_row_limit_stops_acquisition()
    fixture(function(rt, state)
        local server = connect(rt)
        state.rows.session = {}
        state.rows.buffer = { { name = "retained" } }
        local snapshot = assert(server:snapshot({ strict = true }):await())
        t.assertEquals(#snapshot.sessions, 0)
        t.assertEquals(#snapshot.panes, 0)
        t.assertEquals(#snapshot.buffers, 1)
        t.assertEquals(#state.calls, 4)
        state.calls = {}
        state.rows.session = { { id = "$0", name = "one" }, { id = "$1", name = "two" } }
        local value, err = server:snapshot({ max_rows = 1 }):await()
        t.assertNil(value)
        t.assertEquals(err.code, "snapshot_limit")
        t.assertEquals(err.effect, "completed")
        t.assertEquals(#state.calls, 1)
        server:close():await()
    end)
end

function M.test_accumulated_snapshot_respects_runtime_retained_byte_budget()
    fixture(function(rt, state)
        local server = connect(rt)
        rt._limits.max_bytes = 1
        local snapshot, err = server:snapshot():await()
        t.assertNil(snapshot)
        t.assertEquals(err.code, "queue_full")
        t.assertEquals(#state.calls, 1)
        t.assertEquals(rt:stats().bytes, 0)
        server:close():await()
    end)
end

function M.test_close_during_last_verification_cannot_return_live_references()
    fixture(function(rt, state)
        local server = connect(rt)
        state.before = function(index)
            if index == 12 then
                server:close():await()
            end
        end
        local snapshot, err = server:snapshot({ strict = true }):await()
        t.assertNil(snapshot)
        t.assertEquals(err.code, "closed")
        t.assertEquals(#state.calls, 12)
    end)
end

function M.test_cancelled_connect_closes_undelivered_pin_while_root_remains_live()
    fixture(function(rt, state)
        state.resource, state.cancel_delivery = true, true
        state.connect_request = rt:connect({ binary = "/tmux", socket_path = "/owned/socket" })
        local server, err = state.connect_request:await()
        t.assertNil(server)
        assert(err)
        t.assertEquals(err.code, "cancelled")
        -- Let deferred resource cleanup run without completing the root scope.
        rt:_operation(function()
            return true
        end):await()
        t.assertTrue(state.connect_request:is_retired())
        t.assertEquals(rt:stats().resources, 0)
        t.assertTrue(state.closed)
    end)
end

function M.test_cancelled_capture_after_dispatch_does_not_claim_not_sent()
    fixture(function(rt, state)
        local server = connect(rt)
        local request = server:snapshot()
        state.before = function()
            request:cancel()
        end
        local value, err = request:await()
        t.assertNil(value)
        t.assertEquals(err.code, "cancelled")
        t.assertEquals(err.effect, "unknown")
        server:close():await()
    end)
end

function M.test_successful_connect_keeps_pin_until_server_is_closed()
    fixture(function(rt, state)
        state.resource = true
        local server = connect(rt)
        rt:_operation(function()
            return true
        end):await()
        t.assertEquals(rt:stats().resources, 1)
        t.assertNil(state.closed)
        t.assertTrue(server:close():await())
        t.assertEquals(rt:stats().resources, 0)
    end)
end

function M.test_returned_server_state_survives_live_gc_and_releases_root_cycle()
    local watched = setmetatable({}, { __mode = "v" })
    fixture(function(rt)
        local server = connect(rt)
        watched[1] = server
        collectgarbage("collect")
        t.assertNotNil(server:snapshot():await())
        return server
    end)
    collectgarbage("collect")
    collectgarbage("collect")
    t.assertNil(watched[1])
end

function M.test_capture_error_keeps_output_budget_until_caller_delivery()
    fixture(function(rt, state)
        local server = connect(rt)
        state.read_error = {
            code = "read_failed",
            effect = "unknown",
            cause = { partial = { stdout = string.rep("x", 64), stderr = "" } },
        }
        local pending = server:snapshot()
        pending:on_complete(function(value, err)
            t.assertNil(value)
            t.assertEquals(#err.cause.partial.stdout, 64)
            t.assertTrue(rt:stats().bytes >= 64)
        end)
        local value, err = pending:await()
        t.assertNil(value)
        t.assertEquals(err.code, "read_failed")
        server:close():await()
    end)
end

function M.test_live_query_explain_and_whole_validation_dispatch_nothing()
    fixture(function(rt, state)
        local server = connect(rt)
        t.assertEquals(type(server.explain_panes), "function", "live query explain is missing")
        local plan = assert(server:explain_panes({ where = { active = false } }):await())
        t.assertEquals(plan.filter, "#{==:#{pane_active},0}")
        t.assertEquals(plan.source.argv[1], "list-panes")
        t.assertEquals(#state.calls, 0)
        for _, options in ipairs({
            { where = { title = "text" }, pushdown = "require" },
            { where = {}, native_filter = "1" },
            { where = { active = false }, snapshot = { timeout = false } },
            { where = { OR = { {}, { missing = true } } } },
        }) do
            local value, err = server:query_panes(options):await()
            t.assertNil(value)
            t.assertEquals(err.effect, "not_sent")
            t.assertEquals(#state.calls, 0)
        end
        server:close():await()
    end)
end

function M.test_live_query_copies_input_and_preserves_quantified_relationships()
    fixture(function(rt, state)
        local server = connect(rt)
        t.assertEquals(type(server.query_panes), "function", "live query is missing")
        state.rows.pane = {
            { id = "%0", window_id = "@0", index = 0, active = 1 },
            { id = "%1", window_id = "@0", index = 1, active = 0 },
        }
        state.candidate_rows = { state.rows.pane[1], state.rows.pane[1] }
        local options = { where = { active = true } }
        local pending = server:query_panes(options)
        options.where.active = false
        local result = assert(pending:await())
        t.assertEquals(#result.rows, 1)
        t.assertIs(result.rows[1], result.snapshot.panes[1])
        t.assertEquals(#result.rows[1].window.panes, 2)
        t.assertEquals(#state.calls, 7)
        t.assertTrue(result.acquisition.finished >= result.acquisition.started)
        local value = assert(server
            :query_panes({
                where = {
                    active = true,
                    window = { is = { panes = { every = { active = true } } } },
                },
            })
            :await())
        t.assertEquals(#value.rows, 0)
        local local_result = assert(server:query_panes({ pushdown = "never" }):await())
        t.assertEquals(#local_result.rows, 2)
        state.candidate_rows = {}
        local raced = assert(server:query_panes({ where = { active = true } }):await())
        t.assertEquals(#raced.rows, 0)
        t.assertFalse(raced.complete)
        t.assertEquals(raced.races[#raced.races].code, "candidate_changed")
        state.rows.pane[1].active = 0
        state.candidate_rows = { state.rows.pane[2] }
        raced =
            assert(server:query_panes({ where = { active = true }, pushdown = "require" }):await())
        t.assertEquals(#raced.rows, 0)
        t.assertFalse(raced.complete)
        t.assertEquals(raced.races[#raced.races].code, "candidate_changed")
        local buffers = assert(server:query({ kind = "buffer" }):await())
        t.assertEquals(#buffers.rows, 0)
        server:close():await()
    end)
end

function M.test_live_query_missing_candidate_reports_race_and_keeps_delivery_bytes()
    fixture(function(rt, state)
        local server = connect(rt)
        t.assertEquals(type(server.query_panes), "function", "live query is missing")
        state.candidate_rows = { { id = "%99" } }
        local pending = server:query_panes({ where = { id = "%99" } })
        pending:on_complete(function(value, err)
            t.assertNil(err)
            t.assertEquals(#value.rows, 0)
            t.assertFalse(value.complete)
            t.assertEquals(value.races[#value.races].code, "candidate_missing")
            t.assertTrue(rt:stats().bytes > 0)
        end)
        t.assertNotNil(pending:await())
        server:close():await()
    end)
end

return M
