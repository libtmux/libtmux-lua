local lu = require("luaunit")
local driver_module = require("tests.support.runtime_driver")
local tests = {}

---@return any
local function native_uv()
    -- luv is a binary host module, distinct from libtmux.runtime.luv.
    ---@diagnostic disable-next-line: different-requires
    return require("luv")
end

local function fixture(options)
    local ok, runtime = pcall(require, "libtmux._internal.runtime")
    lu.assertTrue(ok, "runtime implementation is missing")
    local driver = driver_module.new()
    return runtime.new(driver, options), driver
end

local function operation(rt, bytes)
    local op = { started = false, stopped = 0 }
    op.request = rt:_request({
        bytes = bytes or 0,
        start = function(settle, retire, request)
            op.started, op.settle, op.retire = true, settle, retire
            op.request = request
            return function(err)
                op.stopped = op.stopped + 1
                op.stop_error = err
            end
        end,
    })
    return op
end

local function error_code(fn, code)
    local ok, err = pcall(fn)
    lu.assertFalse(ok)
    lu.assertEquals(err.code, code)
end

function tests.test_eager_deferred_exactly_once_and_late_callbacks()
    local rt, driver = fixture()
    local op, calls
    calls = {}
    local root = rt:start(function()
        op = operation(rt)
        op.request:on_complete(function(value, err)
            calls[#calls + 1] = { value, err }
        end)
        return "root"
    end)
    driver:drain()
    lu.assertTrue(op.started)
    lu.assertFalse(root:is_settled())
    op.settle("value")
    op.settle("wrong")
    lu.assertEquals(calls, {})
    lu.assertFalse(root:is_settled())
    driver:drain()
    lu.assertEquals(calls, { { "value" } })
    lu.assertFalse(root:is_settled())
    op.request:on_complete(function(value)
        calls[#calls + 1] = { value }
    end)
    lu.assertEquals(#calls, 1)
    driver:drain()
    lu.assertEquals(calls, { { "value" }, { "value" } })
    op.retire()
    driver:drain()
    lu.assertEquals(root:result(), "root")
    lu.assertTrue(root:is_retired())
end

function tests.test_multiple_waiters_and_await_context_even_after_settlement()
    local rt, driver = fixture()
    local op, values
    values = {}
    local root = rt:start(function()
        op = operation(rt)
        for i = 1, 2 do
            rt:spawn(function()
                values[i] = op.request:await()
            end)
        end
    end)
    driver:drain()
    op.settle(42)
    op.retire()
    driver:drain()
    lu.assertEquals(values, { 42, 42 })
    lu.assertTrue(root:is_retired())
    error_code(function()
        op.request:await()
    end, "invalid_await_context")
    local co = coroutine.create(function()
        op.request:await()
    end)
    local ok, err = coroutine.resume(co)
    lu.assertFalse(ok)
    lu.assertEquals(err.code, "invalid_await_context")
    local other, other_driver = fixture()
    local foreign = other:start(function()
        op.request:await()
    end)
    other_driver:drain()
    local _, foreign_err = foreign:result()
    lu.assertEquals(foreign_err.code, "invalid_await_context")
end

function tests.test_borrowed_wait_cancel_detaches_without_stopping_producer()
    local rt, driver = fixture()
    local op, waiter, resumed
    local root = rt:start(function()
        op = operation(rt)
        waiter = rt:spawn(function()
            op.request:await()
            resumed = true
        end)
    end)
    driver:drain()
    waiter:cancel("no longer interested")
    driver:drain()
    lu.assertEquals(op.stopped, 0)
    lu.assertFalse(op.request:is_settled())
    lu.assertTrue(waiter:is_retired())
    op.settle("done")
    op.retire()
    driver:drain()
    lu.assertNil(resumed)
    lu.assertTrue(root:is_retired())
end

function tests.test_owner_cancel_keeps_capacity_until_transport_retirement()
    local rt, driver = fixture({ max_active = 1 })
    local owned, parent, next_op
    local root = rt:start(function()
        parent = rt:spawn(function()
            owned = operation(rt)
            owned.request:await()
        end)
    end)
    driver:drain()
    next_op = operation(rt)
    parent:cancel()
    driver:drain()
    lu.assertEquals(owned.stopped, 1)
    lu.assertFalse(parent:is_retired())
    lu.assertFalse(next_op.started)
    lu.assertEquals(rt:stats().active, 1)
    owned.retire()
    driver:drain()
    lu.assertTrue(parent:is_retired())
    lu.assertTrue(next_op.started)
    next_op.settle(true)
    next_op.retire()
    driver:drain()
    lu.assertTrue(root:is_retired())
end

function tests.test_root_joins_callback_only_finite_chains()
    local rt, driver = fixture()
    local first, second, callback_count
    callback_count = 0
    local root = rt:start(function()
        return "complete"
    end)
    first = operation(rt)
    first.request:on_complete(function()
        second = operation(rt)
        second.request:on_complete(function()
            callback_count = callback_count + 1
        end)
    end)
    driver:drain()
    lu.assertFalse(root:is_settled())
    first.settle(true)
    first.retire()
    driver:drain()
    lu.assertTrue(second.started)
    lu.assertFalse(root:is_settled())
    second.settle(true)
    second.retire()
    driver:drain()
    lu.assertEquals(callback_count, 1)
    lu.assertEquals(root:result(), "complete")
    local rejected = operation(rt).request
    local _, err = rejected:result()
    lu.assertEquals(err.code, "closed")
end

function tests.test_task_failure_after_yield_drains_owned_resources()
    local rt, driver = fixture()
    local marker = { code = "body_failure" }
    local first, remaining
    local root = rt:start(function()
        first = operation(rt)
        remaining = operation(rt)
        first.request:await()
        error(marker)
    end)
    driver:drain()
    first.settle(true)
    first.retire()
    driver:drain()
    local _, err = root:result()
    lu.assertIs(err, marker)
    lu.assertEquals(remaining.stopped, 1)
    lu.assertFalse(root:is_retired())
    remaining.retire()
    driver:drain()
    lu.assertTrue(root:is_retired())
end

function tests.test_close_is_idempotent_and_reports_cleanup_failure()
    local rt, driver = fixture()
    local op
    local root = rt:start(function()
        op = operation(rt)
    end)
    driver:drain()
    lu.assertIs(rt:close(), root)
    lu.assertIs(rt:close(), root)
    lu.assertEquals(op.stopped, 1)
    local rejected = operation(rt).request
    local _, err = rejected:result()
    lu.assertEquals(err.code, "closed")
    op.retire({ code = "cleanup_failed" })
    driver:drain()
    lu.assertTrue(root:is_retired())
    lu.assertEquals(rt:stats().active, 0)
    lu.assertEquals(rt:errors()[1].code, "cleanup_failed")
end

function tests.test_item_byte_and_callback_admission_are_bounded()
    local rt, driver =
        fixture({ max_active = 1, max_pending = 1, max_bytes = 8, max_callbacks = 1 })
    local first, pending, full, large
    local root = rt:start(function()
        first = operation(rt, 4)
        pending = operation(rt, 4)
        full = operation(rt)
        large = operation(rt, 9)
    end)
    driver:drain()
    lu.assertTrue(first.started)
    lu.assertFalse(pending.started)
    for _, req in ipairs({ full.request, large.request }) do
        local _, err = req:result()
        lu.assertEquals(assert(err).code, "queue_full")
    end
    full.request:on_complete(function(_, err)
        lu.assertEquals(err.code, "queue_full")
    end)
    error_code(function()
        large.request:on_complete(function() end)
    end, "queue_full")
    pending.request:cancel()
    lu.assertEquals(rt:stats().bytes, 4)
    lu.assertFalse(first.request:_retain(5))
    lu.assertTrue(first.request:_retain(4))
    driver:drain()
    first.request:on_complete(function() end)
    first.settle("done")
    first.retire()
    lu.assertEquals(rt:stats().bytes, 8)
    driver:drain()
    lu.assertEquals(rt:stats().bytes, 0)
    lu.assertTrue(root:is_retired())
end

function tests.test_deadlines_cover_pending_and_started_requests()
    local rt, driver = fixture({ max_active = 1 })
    local active, pending, stopped
    stopped = 0
    local root = rt:start(function()
        active = rt:_request({
            timeout = 10,
            start = function()
                return function()
                    stopped = stopped + 1
                end
            end,
        })
        pending = rt:_request({
            deadline = 5,
            start = function()
                error("expired request must not start")
            end,
        })
    end)
    driver:drain()
    driver:advance(5)
    local _, err = pending:result()
    lu.assertEquals(err.code, "deadline_exceeded")
    lu.assertTrue(pending:is_retired())
    driver:advance(5)
    _, err = active:result()
    lu.assertEquals(err.code, "deadline_exceeded")
    lu.assertEquals(stopped, 1)
    lu.assertFalse(root:is_retired())
end

function tests.test_callback_failure_is_supervised_and_dispatch_is_fair()
    local rt, driver = fixture({ dispatch_budget = 2 })
    local calls, unrelated, op
    calls = 0
    local root = rt:start(function()
        op = operation(rt)
        for _ = 1, 8 do
            rt:spawn(function()
                calls = calls + 1
            end)
        end
        op.request:on_complete(function()
            error({ code = "callback_failure" })
        end)
    end)
    driver:step()
    driver.defer(function()
        unrelated = calls
    end)
    driver:drain()
    lu.assertTrue(unrelated < 8)
    op.settle(true)
    op.retire()
    driver:drain()
    local _, err = root:result()
    lu.assertEquals(err.code, "callback_failure")
    lu.assertTrue(root:is_retired())
end

function tests.test_child_failure_cannot_be_hidden_by_parent_join()
    local rt, driver = fixture()
    local root = rt:start(function()
        rt:spawn(function()
            error({ code = "child_failure" })
        end)
    end)
    driver:drain()
    local _, err = root:result()
    lu.assertNotNil(err)
    lu.assertEquals(err.code, "child_failure")
    lu.assertTrue(root:is_retired())
end

function tests.test_root_completion_callback_does_not_wait_for_itself()
    local rt, driver = fixture()
    local seen
    local root = rt:start(function()
        return 42
    end)
    root:on_complete(function(value)
        seen = value
    end)
    driver:drain()
    lu.assertEquals(seen, 42)
    lu.assertTrue(root:is_retired())
end

function tests.test_cancelled_submissions_do_not_accumulate_runnable_work()
    local rt, driver = fixture({ max_active = 1, max_pending = 0, max_tasks = 2 })
    local root = rt:start(function()
        for _ = 1, 1000 do
            operation(rt).request:cancel()
            rt:spawn(function()
                error("cancelled task ran")
            end):cancel()
        end
        lu.assertTrue(rt:stats().runnable <= 2)
    end)
    driver:drain()
    local _, err = root:result()
    lu.assertNil(err)
    lu.assertEquals(rt:stats().runnable, 0)
end

function tests.test_cancel_during_start_invokes_late_registered_hook_once()
    local rt, driver = fixture()
    local stopped, finish
    stopped = 0
    local root = rt:start(function()
        rt:_request({
            start = function(_, retire, req)
                finish = retire
                req:cancel()
                return function()
                    stopped = stopped + 1
                end
            end,
        })
    end)
    driver:drain()
    lu.assertEquals(stopped, 1)
    lu.assertFalse(root:is_retired())
    finish()
    driver:drain()
    lu.assertTrue(root:is_retired())
end

function tests.test_sync_completion_before_await_does_not_lose_wakeup()
    local rt, driver = fixture()
    local result
    local root = rt:start(function()
        result = rt:_request({
            start = function(settle, retire)
                settle(42)
                retire()
            end,
        }):await()
    end)
    driver:drain()
    lu.assertEquals(result, 42)
    lu.assertTrue(root:is_retired())
end

function tests.test_luv_adapter_is_optional_and_drains_owned_loop_work()
    local ok, adapter = pcall(require, "libtmux.runtime.luv")
    lu.assertTrue(ok, "luv adapter implementation is missing")
    local called = false
    local rt
    local value, err = adapter.run(function(runtime)
        ---@cast runtime libtmux.TestRuntime
        rt = runtime
        local req = runtime:_request({
            timeout = 100,
            start = function(settle, retire)
                local cancel = runtime._driver.timer(0, function()
                    settle("done")
                    retire()
                end)
                return function()
                    cancel()
                    retire()
                end
            end,
        })
        req:on_complete(function()
            called = true
        end)
        return req:await()
    end)
    lu.assertEquals(value, "done")
    lu.assertNil(err)
    lu.assertTrue(called)
    lu.assertEquals(rt:stats().active, 0)
    lu.assertFalse(native_uv().loop_alive())
end

function tests.test_luv_adapter_rejects_borrowed_or_nested_loop_driving()
    local ok, adapter = pcall(require, "libtmux.runtime.luv")
    lu.assertTrue(ok, "luv adapter implementation is missing")
    local uv = native_uv()
    local timer = uv.new_timer()
    timer:start(0, 0, function()
        timer:close()
    end)
    local _, err = adapter.run(function() end)
    lu.assertEquals(assert(err).code, "invalid_run_context")
    uv.run()
    local value
    value, err = adapter.run(function()
        local _, nested = adapter.run(function() end)
        return assert(nested).code
    end)
    lu.assertEquals(value, "invalid_run_context")
    lu.assertNil(err)
end

function tests.test_closed_callback_registration_cannot_reopen_owned_driver()
    local rt, driver = fixture()
    local root = rt:start(function()
        return 42
    end)
    driver:drain()
    error_code(function()
        root:on_complete(function() end)
    end, "closed")
    lu.assertEquals(#driver.ready, 0)
    lu.assertEquals(rt:stats().callbacks, 0)
    lu.assertEquals(root:result(), 42)
end

function tests.test_request_cancellation_copies_context_and_effect()
    local rt, driver = fixture()
    local req, finish, seen
    local reason = { code = "cancelled", message = "root closed" }
    local root = rt:start(function()
        req = rt:_request({
            effect = "not_sent",
            operation = "process",
            target = "tmux",
            start = function(_, retire, request)
                request:_set_effect("unknown")
                finish = retire
                return function(err)
                    seen = err
                    err.partial = "some output"
                end
            end,
        })
    end)
    driver:drain()
    req:cancel(reason)
    lu.assertNotIs(seen, reason)
    lu.assertEquals(reason, { code = "cancelled", message = "root closed" })
    local _, err = req:result()
    lu.assertEquals(err.effect, "unknown")
    lu.assertEquals(err.operation, "process")
    lu.assertEquals(err.target, "tmux")
    lu.assertEquals(err.partial, "some output")
    finish()
    driver:drain()
    lu.assertTrue(root:is_retired())
end

function tests.test_luv_stalled_root_drains_cancellation_timer_before_return()
    local adapter = require("libtmux.runtime.luv")
    local retired, root
    local _, err = adapter.run(function(rt)
        ---@cast rt libtmux.TestRuntime
        root = rt
        rt:_request({
            start = function(_, retire)
                return function()
                    rt._driver.timer(0, function()
                        retired = true
                        retire()
                    end)
                end
            end,
        })
    end)
    local leaked = native_uv().loop_alive()
    if leaked then
        native_uv().run()
    end
    lu.assertEquals(assert(err).code, "runtime_stalled")
    lu.assertTrue(retired)
    lu.assertFalse(leaked)
    lu.assertEquals(root:stats().active, 0)
end

function tests.test_luv_host_exception_drains_transport_before_return()
    local adapter, uv = require("libtmux.runtime.luv"), native_uv()
    local original_run = uv.run
    local started, injected, retired
    uv.run = function(mode)
        local result = original_run(mode)
        if started and not injected then
            injected = true
            error("injected host callback failure")
        end
        return result
    end
    local _, err = adapter.run(function(rt)
        ---@cast rt libtmux.TestRuntime
        rt:_request({
            start = function(_, retire)
                started = true
                return function()
                    rt._driver.timer(0, function()
                        retired = true
                        retire()
                    end)
                end
            end,
        })
    end)
    uv.run = original_run
    local leaked = uv.loop_alive()
    if leaked then
        uv.run()
    end
    lu.assertEquals((err --[[@as table]]).code, "host_error")
    lu.assertTrue(retired)
    lu.assertFalse(leaked)
end

function tests.test_driver_timer_cleanup_error_preserves_callback_and_retirement()
    local rt, driver = fixture()
    local called
    -- Inject failure into the host timer cancellation boundary.
    ---@diagnostic disable-next-line: duplicate-set-field
    driver.timer = function()
        return function()
            error("timer cleanup failed")
        end
    end
    local root = rt:start(function()
        rt:_request({
            timeout = 10,
            start = function(settle, retire)
                settle("done")
                retire()
            end,
        }):on_complete(function(value)
            called = value
        end)
    end)
    driver:drain()
    lu.assertEquals(called, "done")
    lu.assertTrue(root:is_retired())
    lu.assertEquals(rt:errors()[1].code, "cleanup_failed")
end

function tests.test_close_before_start_is_idempotent_and_rejects_callbacks()
    local rt, driver = fixture()
    local closed = rt:close()
    lu.assertIs(rt:close(), closed)
    error_code(function()
        closed:on_complete(function() end)
    end, "closed")
    lu.assertEquals(#driver.ready, 0)
    local _, err = rt:start(function() end):result()
    lu.assertEquals(assert(err).code, "closed")
end

function tests.test_settled_transport_cleanup_cannot_mutate_root_error()
    local rt, driver = fixture()
    local marker = { code = "root_failure", message = "original" }
    local root = rt:start(function()
        rt:_request({
            effect = "completed",
            start = function(settle, retire)
                settle("done")
                return function(err)
                    err.polluted = true
                    retire()
                end
            end,
        }):await()
        error(marker)
    end)
    driver:drain()
    local _, err = root:result()
    lu.assertIs(err, marker)
    lu.assertEquals(marker, { code = "root_failure", message = "original" })
    lu.assertTrue(root:is_retired())
end

function tests.test_large_timer_delay_is_rejected_before_allocating_native_handle()
    local uv = native_uv()
    local adapter = require("libtmux.runtime.luv")
    local driver = adapter._driver(uv)
    local ok, err = pcall(driver.timer, 1e20, function() end)
    local handles = 0
    uv.walk(function(handle)
        handles = handles + 1
        if not handle:is_closing() then
            handle:close()
        end
    end)
    uv.run()
    lu.assertFalse(ok)
    lu.assertEquals(handles, 0)
    lu.assertEquals((err --[[@as table]]).code, "invalid_timer")
    lu.assertEquals(driver.pending, 0)
end

function tests.test_request_timer_failure_settles_and_retires_request()
    local rt, driver = fixture()
    -- Inject failure before the host can register a timer.
    ---@diagnostic disable-next-line: duplicate-set-field
    driver.timer = function()
        error("timer creation failed")
    end
    local req
    local root = rt:start(function()
        req = rt:_request({
            timeout = 1,
            start = function()
                error("timer-failed request started")
            end,
        })
        local _, err = req:await()
        lu.assertEquals((err --[[@as table]]).code, "host_error")
    end)
    driver:drain()
    lu.assertNotNil(req)
    lu.assertTrue(req:is_retired())
    local _, err = root:result()
    lu.assertNil(err)
    lu.assertTrue(root:is_retired())
end

function tests.test_queued_waiter_deliveries_retain_bytes_until_resume_or_cancel()
    local rt, driver = fixture({ max_bytes = 4 })
    local op, waiter
    local root = rt:start(function()
        op = operation(rt, 4)
        waiter = rt:spawn(function()
            op.request:await()
        end)
        rt:spawn(function()
            op.request:await()
        end)
    end)
    driver:drain()
    op.settle("data")
    op.retire()
    lu.assertEquals(rt:stats().bytes, 4)
    waiter:cancel()
    lu.assertEquals(rt:stats().bytes, 4)
    driver:drain()
    lu.assertEquals(rt:stats().bytes, 0)
    lu.assertTrue(root:is_retired())
end

function tests.test_native_timer_start_failure_closes_allocated_handle()
    local uv = native_uv()
    local adapter = require("libtmux.runtime.luv")
    local driver = adapter._driver({
        new_timer = function()
            local handle = uv.new_timer()
            return {
                start = function()
                    error("injected timer start failure")
                end,
                stop = function()
                    handle:stop()
                end,
                close = function(_, callback)
                    handle:close(callback)
                end,
            }
        end,
    })
    local ok, err = pcall(driver.timer, 1, function() end)
    uv.run()
    local remaining = 0
    uv.walk(function()
        remaining = remaining + 1
    end)
    lu.assertFalse(ok)
    lu.assertEquals((err --[[@as table]]).code, "host_error")
    lu.assertEquals(driver.pending, 0)
    lu.assertEquals(remaining, 0)
end

function tests.test_standalone_adapter_rejects_neovim_outside_fast_events()
    local adapter = require("libtmux.runtime.luv")
    local original = rawget(_G, "vim")
    rawset(_G, "vim", {
        in_fast_event = function()
            return false
        end,
    })
    local called = false
    local _, err = adapter.run(function()
        called = true
    end)
    rawset(_G, "vim", original)
    lu.assertFalse(called)
    lu.assertEquals(assert(err).code, "invalid_run_context")
end

function tests.test_cleanup_guard_allocation_failure_does_not_poison_next_run()
    local uv = native_uv()
    local adapter = require("libtmux.runtime.luv")
    local original_run, original_timer = uv.run, uv.new_timer
    local allocations = 0
    uv.new_timer = function()
        allocations = allocations + 1
        if allocations == 2 then
            return nil, "injected allocation failure"
        end
        return original_timer()
    end
    uv.run = function()
        error("injected loop failure")
    end
    local ok, _, err = pcall(adapter.run, function() end)
    uv.run, uv.new_timer = original_run, original_timer
    uv.run()
    local value, next_err = adapter.run(function()
        return 42
    end)
    lu.assertTrue(ok)
    lu.assertEquals(assert(err).code, "cleanup_failed")
    lu.assertEquals(value, 42)
    lu.assertNil(next_err)
end

function tests.test_initial_dispatch_failure_does_not_leave_a_live_task()
    local rt, driver = fixture()
    ---@diagnostic disable-next-line: duplicate-set-field
    driver.defer = function()
        error("dispatch unavailable")
    end
    local ok, root = pcall(rt.start, rt, function()
        error("undispatched task ran")
    end)
    lu.assertTrue(ok)
    local _, err = root:result()
    lu.assertEquals(err.code, "host_error")
    lu.assertTrue(root:is_retired())
    lu.assertEquals(rt:stats().tasks, 0)
    lu.assertEquals(rt:stats().runnable, 0)
end

function tests.test_neovim_schedule_failure_returns_structured_error()
    local adapter = require("libtmux.runtime.nvim")
    local original = rawget(_G, "vim")
    rawset(_G, "vim", {
        uv = native_uv(),
        schedule = function()
            error("editor scheduling unavailable")
        end,
    })
    local ok, runtime, err = pcall(adapter.start, function() end, function() end)
    rawset(_G, "vim", original)
    lu.assertTrue(ok)
    lu.assertNil(runtime)
    lu.assertEquals(err.code, "host_error")
end

function tests.test_callback_failure_during_cancel_is_reported_without_replacing_root_error()
    local rt, driver = fixture()
    local op
    local root = rt:start(function()
        op = operation(rt)
        op.request:on_complete(function()
            error({ code = "cleanup_callback_failure" })
        end)
    end)
    driver:drain()
    root:cancel()
    op.retire()
    driver:drain()
    local _, err = root:result()
    lu.assertEquals(err.code, "cancelled")
    local failures = rt:errors()
    lu.assertEquals(#failures, 1)
    lu.assertEquals(failures[1].code, "cleanup_callback_failure")
end

function tests.test_waiter_dispatch_failure_aborts_scope_and_releases_deliveries()
    local rt, driver = fixture({ max_bytes = 4 })
    local op, resumed
    resumed = 0
    local root = rt:start(function()
        op = operation(rt, 4)
        for _ = 1, 2 do
            rt:spawn(function()
                op.request:await()
                resumed = resumed + 1
            end)
        end
    end)
    driver:drain()
    local defer = driver.defer
    ---@diagnostic disable-next-line: duplicate-set-field
    driver.defer = function()
        driver.defer = defer
        error("transient waiter dispatch failure")
    end
    local ok = pcall(op.settle, "data")
    lu.assertTrue(ok)
    local _, err = root:result()
    lu.assertEquals(err.code, "host_error")
    lu.assertFalse(root:is_retired())
    lu.assertEquals(rt:stats().active, 1)
    lu.assertEquals(rt:stats().bytes, 4)
    op.retire()
    driver:drain()
    lu.assertTrue(root:is_retired())
    lu.assertEquals(resumed, 0)
    lu.assertEquals(rt:stats().bytes, 0)
    lu.assertEquals(rt:stats().tasks, 0)
    lu.assertEquals(rt:stats().runnable, 0)
end

function tests.test_callback_dispatch_failure_releases_callback_reservations()
    local rt, driver = fixture({ max_bytes = 4 })
    local op, called
    local root = rt:start(function()
        op = operation(rt, 4)
        op.request:on_complete(function()
            called = true
        end)
    end)
    driver:drain()
    ---@diagnostic disable-next-line: duplicate-set-field
    driver.defer = function()
        error("persistent completion dispatch failure")
    end
    local ok = pcall(op.settle, "data")
    op.retire()
    driver:drain()
    lu.assertTrue(ok)
    local _, err = root:result()
    lu.assertEquals(err.code, "host_error")
    lu.assertTrue(root:is_retired())
    lu.assertNil(called)
    lu.assertEquals(rt:stats().bytes, 0)
    lu.assertEquals(rt:stats().callbacks, 0)
    lu.assertEquals(rt:stats().runnable, 0)
end

function tests.test_reschedule_failure_rejects_remaining_callback_backlog()
    local rt, driver = fixture({ max_bytes = 4, dispatch_budget = 1 })
    local op, calls
    calls = 0
    local root = rt:start(function()
        op = operation(rt, 4)
        for _ = 1, 2 do
            op.request:on_complete(function()
                calls = calls + 1
            end)
        end
    end)
    driver:drain()
    op.settle("data")
    op.retire()
    ---@diagnostic disable-next-line: duplicate-set-field
    driver.defer = function()
        error("callback backlog reschedule failure")
    end
    local ok = pcall(driver.step, driver)
    lu.assertTrue(ok)
    local _, err = root:result()
    lu.assertEquals(err.code, "host_error")
    lu.assertTrue(root:is_retired())
    lu.assertEquals(calls, 1)
    lu.assertEquals(rt:stats().bytes, 0)
    lu.assertEquals(rt:stats().callbacks, 0)
    lu.assertEquals(rt:stats().runnable, 0)
end

function tests.test_operation_awaits_children_without_consuming_transport_capacity()
    local rt, driver = fixture({ max_active = 1 })
    lu.assertEquals(type(rt._operation), "function", "composite operations are missing")
    local child, composite
    local root = rt:start(function()
        composite = rt:_operation(function(runtime, req)
            lu.assertIs(runtime, rt)
            lu.assertIs(req, composite)
            child = operation(rt)
            local value, err = child.request:await()
            if err then
                return nil, err
            end
            return value + 1
        end)
        return composite:await()
    end)
    driver:drain()
    lu.assertTrue(child.started)
    lu.assertEquals(rt:stats().active, 1)
    child.settle(40)
    driver:drain()
    lu.assertFalse(composite:is_settled())
    child.retire()
    driver:drain()
    lu.assertEquals(root:result(), 41)
    lu.assertTrue(root:is_retired())
end

function tests.test_operation_failures_stop_at_the_nearest_boundary()
    local rt, driver = fixture()
    lu.assertEquals(type(rt._operation), "function", "composite operations are missing")
    local marker = { code = "expected_operation_failure" }
    local unrelated, seen
    seen = {}
    local root = rt:start(function()
        unrelated = operation(rt)
        for index = 1, 3 do
            local composite = rt:_operation(function()
                if index == 1 then
                    return nil, marker
                elseif index == 2 then
                    error(marker)
                end
                rt:spawn(function()
                    error(marker)
                end)
            end)
            local value, err = composite:await()
            lu.assertNil(value)
            seen[index] = err
        end
        return "continued"
    end)
    driver:drain()
    lu.assertEquals(seen, { marker, marker, marker })
    lu.assertEquals(unrelated.stopped, 0)
    unrelated.settle(true)
    unrelated.retire()
    driver:drain()
    lu.assertEquals(root:result(), "continued")
end

function tests.test_operation_cancellation_copies_context_and_joins_child_retirement()
    local rt, driver = fixture({ max_active = 1 })
    lu.assertEquals(type(rt._operation), "function", "composite operations are missing")
    local context = { operation = "bind", target = "owned", partial = { stage = "allocated" } }
    local child, composite, observed
    local root = rt:start(function()
        composite = rt:_operation(function(_, req)
            req:_set_effect("unknown")
            child = operation(rt)
            child.request:await()
        end, context)
        local _, err = composite:await()
        observed = err
        return "caught"
    end)
    driver:drain()
    context.operation, context.partial.stage = "changed", "changed"
    local reason = { code = "cancelled", message = "stop", partial = { stage = "reason" } }
    lu.assertTrue(composite:cancel(reason))
    driver:drain()
    lu.assertEquals(observed.operation, "bind")
    lu.assertEquals(observed.target, "owned")
    lu.assertEquals(observed.effect, "unknown")
    lu.assertEquals(observed.partial, { stage = "allocated" })
    lu.assertNotIs(observed.partial, context.partial)
    lu.assertNotIs(observed.partial, reason.partial)
    lu.assertEquals(child.stopped, 1)
    child.stop_error.partial.stage = "cleanup changed"
    lu.assertEquals(observed.partial.stage, "allocated")
    lu.assertFalse(composite:is_retired())
    lu.assertFalse(root:is_retired())
    child.retire()
    driver:drain()
    lu.assertTrue(composite:is_retired())
    lu.assertEquals(root:result(), "caught")
end

function tests.test_resources_close_after_owned_callbacks_and_before_root_completion()
    local rt, driver = fixture()
    lu.assertEquals(type(rt._resource), "function", "owned resources are missing")
    local first, second, finish_close, lease
    local events = {}
    local root = rt:start(function()
        lease = assert(rt:_resource(function(done)
            events[#events + 1] = "closing"
            finish_close = done
        end))
        first = operation(rt)
        first.request:on_complete(function()
            events[#events + 1] = "callback"
            second = operation(rt)
        end)
        return "result"
    end)
    root:on_complete(function()
        events[#events + 1] = "complete"
    end)
    driver:drain()
    first.settle(true)
    first.retire()
    driver:drain()
    lu.assertEquals(events, { "callback" })
    second.settle(true)
    second.retire()
    lu.assertEquals(events, { "callback" })
    driver:drain()
    lu.assertEquals(events, { "callback", "closing" })
    lu.assertEquals(rt:stats().resources, 1)
    lu.assertEquals(rt:stats().resources_closing, 1)
    lu.assertFalse(root:is_settled())
    finish_close()
    lu.assertEquals(events, { "callback", "closing" })
    driver:drain()
    lu.assertEquals(events, { "callback", "closing", "complete" })
    lu.assertEquals(root:result(), "result")
    lu.assertTrue(root:is_retired())
    lu.assertTrue(lease:close():is_retired())
    lu.assertEquals(rt:stats().resources, 0)
    lu.assertEquals(rt:stats().resources_closing, 0)
end

function tests.test_resource_close_is_idempotent_bounded_and_outside_transport_slots()
    local rt, driver = fixture({ max_active = 1, max_resources = 1 })
    local lease, close, child, done
    local closes = 0
    local root = rt:start(function()
        lease = assert(rt:_resource(function(finish)
            closes, done = closes + 1, finish
        end))
        local rejected, err = rt:_resource(function() end)
        lu.assertNil(rejected)
        lu.assertEquals(assert(err).code, "queue_full")
        child = operation(rt)
        close = lease:close()
        lu.assertIs(lease:close(), close)
        lu.assertFalse(close:cancel())
        lu.assertEquals(closes, 0)
        local value, close_err = close:await()
        lu.assertTrue(value)
        lu.assertNil(close_err)
        return "closed explicitly"
    end)
    driver:drain()
    lu.assertEquals(closes, 1)
    lu.assertTrue(child.started)
    lu.assertEquals(rt:stats().active, 1)
    done()
    done({ code = "duplicate_completion" })
    driver:drain()
    lu.assertTrue(close:is_retired())
    lu.assertFalse(root:is_retired())
    child.settle(true)
    child.retire()
    driver:drain()
    lu.assertEquals(root:result(), "closed explicitly")
    lu.assertEquals(rt:stats().resources_failed, 0)
    local rejected, err = rt:_resource(function() end)
    lu.assertNil(rejected)
    lu.assertEquals(assert(err).code, "closed")
end

function tests.test_resource_cleanup_errors_are_visible_and_preserve_root_failure()
    for _, root_error in ipairs({ false, { code = "original_failure" } }) do
        local rt, driver = fixture()
        lu.assertEquals(type(rt._resource), "function", "owned resources are missing")
        local marker = { code = "native_cleanup_failed" }
        local root = rt:start(function()
            assert(rt:_resource(function(done)
                done(marker)
            end))
            assert(rt:_resource(function()
                error(marker)
            end))
            if root_error then
                error(root_error)
            end
            return "must not report success"
        end)
        driver:drain()
        local value, err = root:result()
        lu.assertNil(value)
        if root_error then
            lu.assertIs(err, root_error)
        else
            lu.assertEquals(assert(err).code, "cleanup_failed")
        end
        lu.assertTrue(root:is_retired())
        lu.assertEquals(rt:stats().resources, 0)
        lu.assertEquals(rt:stats().resources_closing, 0)
        lu.assertEquals(rt:stats().resources_failed, 2)
        lu.assertEquals(#rt:errors(), 2)
        lu.assertEquals(rt:errors()[1].code, "cleanup_failed")
        lu.assertIs(rt:errors()[1].cause, marker)
    end
end

function tests.test_retirement_bookkeeping_is_single_synchronous_and_protected()
    local rt, driver = fixture()
    local child, retired
    retired = 0
    local root = rt:start(function()
        child = operation(rt)
    end)
    driver:drain()
    lu.assertEquals(type(child.request._on_retire), "function", "retirement hooks are missing")
    child.request:_on_retire(function()
        retired = retired + 1
        lu.assertTrue(child.request:is_retired())
        error("bookkeeping failure")
    end)
    error_code(function()
        child.request:_on_retire(function() end)
    end, "invalid_callback")
    child.settle(true)
    lu.assertEquals(retired, 0)
    child.retire()
    child.retire()
    lu.assertEquals(retired, 1)
    lu.assertEquals(rt:errors()[1].code, "cleanup_failed")
    root:_on_retire(function()
        retired = retired + 1
    end)
    lu.assertEquals(retired, 2)
    driver:drain()
    lu.assertTrue(root:is_retired())
end

function tests.test_resource_cleanup_starts_once_when_host_dispatch_fails()
    local rt, driver = fixture()
    local finishes, calls, completed = {}, 0, 0
    local root = rt:start(function()
        for index = 1, 2 do
            assert(rt:_resource(function(done)
                calls = calls + 1
                finishes[index] = done
            end))
        end
        return "host must not report success"
    end)
    root:on_complete(function()
        completed = completed + 1
    end)
    ---@diagnostic disable-next-line: duplicate-set-field
    driver.defer = function()
        error("resource close dispatch failed")
    end
    driver:drain()
    lu.assertEquals(calls, 2)
    lu.assertEquals(rt:stats().resources, 2)
    lu.assertEquals(rt:stats().resources_closing, 2)
    lu.assertFalse(root:is_retired())
    finishes[1]()
    lu.assertFalse(root:is_retired())
    finishes[2]()
    lu.assertTrue(root:is_retired())
    local value, err = root:result()
    lu.assertNil(value)
    lu.assertEquals(err.code, "host_error")
    lu.assertEquals(rt:stats().resources, 0)
    lu.assertEquals(rt:stats().resources_failed, 0)
    lu.assertEquals(rt:stats().tasks, 0)
    lu.assertEquals(completed, 0)
end

function tests.test_synchronous_resource_cleanup_cannot_retire_root_twice()
    local rt, driver = fixture()
    local calls = 0
    local root = rt:start(function()
        for _ = 1, 2 do
            assert(rt:_resource(function(done)
                calls = calls + 1
                done()
            end))
        end
    end)
    ---@diagnostic disable-next-line: duplicate-set-field
    driver.defer = function()
        error("resource close dispatch failed")
    end
    driver:drain()
    lu.assertEquals(calls, 2)
    lu.assertTrue(root:is_retired())
    lu.assertEquals(rt:stats().tasks, 0)
    lu.assertEquals(rt:stats().resources, 0)
end

function tests.test_logical_requests_do_not_consume_process_slots_and_keep_retirement_capacity()
    local rt, driver = fixture({ max_active = 1, max_pending = 0, max_logical = 16 })
    local waiting, progressed = {}, false
    local root = rt:start(function()
        for index = 1, 16 do
            local item = {}
            waiting[index] = item
            item.request = rt:_logical_request({
                effect = "not_sent",
                start = function(settle, retire)
                    item.settle, item.retire = settle, retire
                    return function()
                        item.cancelled = true
                    end
                end,
            })
        end
        local rejected = rt:_logical_request({
            start = function()
                error("rejected start")
            end,
        })
        lu.assertEquals(select(2, rejected:result()).code, "queue_full")
        progressed = rt:_request({
            start = function(settle, retire)
                settle(true)
                retire()
            end,
        }):await() == true
    end)
    driver:drain()
    lu.assertTrue(progressed)
    lu.assertEquals(rt:stats().logical, 16)
    lu.assertEquals(rt:stats().active, 0)
    lu.assertEquals(rt:stats().pending, 0)
    lu.assertFalse(root:is_retired())
    waiting[1].request:cancel()
    lu.assertTrue(waiting[1].cancelled)
    lu.assertEquals(rt:stats().logical, 16)
    waiting[1].retire()
    lu.assertEquals(rt:stats().logical, 15)
    local next_request = rt:_logical_request({
        start = function(settle, retire)
            settle(true)
            retire()
        end,
    })
    driver:drain()
    lu.assertTrue(next_request:is_retired())
    for index = 2, 16 do
        waiting[index].request:cancel()
        waiting[index].retire()
    end
    driver:drain()
    lu.assertTrue(root:is_retired())
    lu.assertEquals(rt:stats().logical, 0)
    lu.assertEquals(select(2, rt:_logical_request({}):result()).code, "closed")
end

function tests.test_logical_registration_race_deadline_and_borrowed_wait_ownership()
    local rt, driver = fixture()
    local calls, detached = 0, 0
    local timeout, producer, waiter
    local root = rt:start(function()
        local racing = rt:_logical_request({
            start = function(_, retire, request)
                request:cancel()
                return function()
                    detached = detached + 1
                    retire()
                end
            end,
        })
        racing:on_complete(function(_, err)
            lu.assertEquals(err.code, "cancelled")
            calls = calls + 1
        end)
        timeout = rt:_logical_request({
            timeout = 5,
            start = function(_, retire)
                return function()
                    detached = detached + 1
                    retire()
                end
            end,
        })
        producer = rt:_logical_request({
            start = function(_, retire)
                return function()
                    detached = detached + 1
                    retire()
                end
            end,
        })
        waiter = rt:_operation(function()
            producer:await()
        end)
    end)
    driver:drain()
    lu.assertEquals(calls, 1)
    lu.assertEquals(detached, 1)
    waiter:cancel()
    driver:drain()
    lu.assertFalse(producer:is_settled())
    lu.assertEquals(detached, 1)
    driver:advance(5)
    lu.assertEquals(select(2, timeout:result()).code, "deadline_exceeded")
    lu.assertEquals(detached, 2)
    rt:close()
    driver:drain()
    lu.assertEquals(detached, 3)
    lu.assertTrue(root:is_retired())
    lu.assertEquals(rt:stats().logical, 0)
end

function tests.test_resource_budget_transfer_keeps_exact_limit_through_delivery()
    local rt, driver = fixture({ max_bytes = 8 })
    local budget, pending, settle, retire, delivered
    local root = rt:start(function()
        local lease = assert(rt:_resource(function(done)
            lu.assertEquals(budget:bytes(), 0)
            done()
        end))
        budget = assert(lease:_budget(8))
        lu.assertIs(lease:_budget(8), budget)
        lu.assertTrue(budget:retain(8))
        lu.assertEquals(select(2, budget:retain(1)).code, "queue_full")
        pending = rt:_logical_request({
            start = function(done, cleanup)
                settle, retire = done, cleanup
            end,
        })
        pending:on_complete(function(value, err)
            lu.assertNil(err)
            lu.assertEquals(value, "12345678")
            lu.assertEquals(rt:stats().bytes, 8)
            delivered = true
        end)
        return pending:await()
    end)
    driver:drain()
    lu.assertEquals(rt:stats().resource_bytes, 8)
    lu.assertTrue(budget:transfer(pending, 8))
    lu.assertEquals(budget:bytes(), 0)
    lu.assertEquals(rt:stats().resource_bytes, 0)
    lu.assertEquals(rt:stats().bytes, 8)
    lu.assertEquals(pending._cost, 8)
    settle("12345678")
    retire()
    lu.assertNil(delivered)
    lu.assertEquals(rt:stats().bytes, 8)
    driver:drain()
    lu.assertTrue(delivered)
    lu.assertEquals(root:result(), "12345678")
    lu.assertTrue(root:is_retired())
    lu.assertEquals(rt:stats().bytes, 0)
end

function tests.test_resource_budget_validation_and_close_cannot_lose_charges()
    local rt, driver = fixture({ max_bytes = 8 })
    local other, other_driver = fixture()
    local foreign = other:start(function()
        return true
    end)
    local budget, finish, lease
    local root = rt:start(function()
        lease = assert(rt:_resource(function(done)
            finish = done
        end))
        budget = assert(lease:_budget(6))
        lu.assertTrue(budget:retain(6))
        local shared
        local other_lease = assert(rt:_resource(function(done)
            lu.assertTrue(shared:release(2))
            done()
        end))
        shared = assert(other_lease:_budget(6))
        lu.assertEquals(select(2, shared:retain(3)).code, "queue_full")
        lu.assertTrue(shared:retain(2))
        local rejected = rt:_logical_request({
            bytes = 1,
            start = function()
                error("over-budget logical request started")
            end,
        })
        lu.assertEquals(select(2, rejected:result()).code, "queue_full")
        lu.assertEquals(select(2, lease:_budget(7)).code, "invalid_options")
        for _, count in ipairs({ -1, 0.5, math.huge, 7 }) do
            lu.assertNil(budget:release(count))
        end
        lu.assertEquals(select(2, budget:transfer(foreign, 1)).code, "invalid_request")
        lu.assertEquals(select(2, budget:transfer({}, 1)).code, "invalid_request")
        local settled = rt:_logical_request({
            start = function(done, cleanup)
                done(true)
                cleanup()
            end,
        })
        settled:await()
        lu.assertEquals(select(2, budget:transfer(settled, 1)).code, "invalid_request")
        lu.assertEquals(budget:bytes(), 6)
        lease:close()
        lu.assertEquals(select(2, budget:retain(1)).code, "closed")
        lu.assertTrue(budget:release(2))
    end)
    driver:drain()
    lu.assertFalse(root:is_retired())
    finish()
    driver:drain()
    local _, err = root:result()
    lu.assertEquals(err.code, "cleanup_failed")
    lu.assertEquals(err.cause.retained_bytes, 4)
    lu.assertEquals(rt:stats().resources_failed, 1)
    lu.assertEquals(rt:stats().resource_bytes, 4)
    lu.assertEquals(rt:stats().bytes, 4)
    lu.assertTrue(budget:release(4))
    lu.assertEquals(rt:stats().bytes, 0)
    lu.assertEquals(rt:stats().resource_bytes, 0)
    other_driver:drain()
end

function tests.test_resource_budget_async_cleanup_drains_after_logical_cancellation()
    local rt, driver = fixture({ max_bytes = 8 })
    local budget, release, waiting
    local detached = false
    local root = rt:start(function()
        local lease = assert(rt:_resource(function(done)
            lu.assertTrue(detached)
            release = function()
                lu.assertTrue(budget:release(8))
                done()
            end
        end))
        budget = assert(lease:_budget(8))
        lu.assertTrue(budget:retain(8))
        waiting = rt:_logical_request({
            start = function(_, retire)
                return function()
                    detached = true
                    retire()
                end
            end,
        })
        return waiting:await()
    end)
    driver:drain()
    rt:close()
    driver:drain()
    lu.assertTrue(waiting:is_retired())
    lu.assertFalse(root:is_retired())
    lu.assertEquals(rt:stats().resource_bytes, 8)
    release()
    driver:drain()
    lu.assertTrue(root:is_retired())
    lu.assertEquals(rt:stats().bytes, 0)
    lu.assertEquals(rt:stats().resources, 0)
end

function tests.test_host_dispatch_failure_still_releases_resource_budget_and_logical_waiter()
    local rt, driver = fixture()
    local budget, settle, retire, callbacks
    callbacks = 0
    local root = rt:start(function()
        local lease = assert(rt:_resource(function(done)
            lu.assertTrue(budget:release(4))
            done()
        end))
        budget = assert(lease:_budget(4))
        lu.assertTrue(budget:retain(4))
        local waiting = rt:_logical_request({
            start = function(done, cleanup)
                settle, retire = done, cleanup
                return cleanup
            end,
        })
        waiting:on_complete(function()
            callbacks = callbacks + 1
        end)
        return waiting:await()
    end)
    driver:drain()
    rawset(driver, "defer", function()
        error("dispatcher unavailable")
    end)
    settle("ready")
    retire()
    driver:drain()
    lu.assertEquals(select(2, root:result()).code, "host_error")
    lu.assertTrue(root:is_retired())
    lu.assertEquals(callbacks, 0)
    lu.assertEquals(rt:stats().bytes, 0)
    lu.assertEquals(rt:stats().resource_bytes, 0)
    lu.assertEquals(rt:stats().logical, 0)
    lu.assertEquals(rt:stats().resources, 0)
end

return tests
