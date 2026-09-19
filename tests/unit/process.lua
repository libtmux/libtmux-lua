local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local ok, process = pcall(require, "libtmux._internal.process")
local M = {}

local function fixture(options)
    t.assertTrue(ok, "PROCESS transport module is not implemented")
    local driver, handles = drivers.new(), {}
    local uv = {}
    function uv.new_pipe()
        local pipe = { closed = false }
        function pipe:read_start(fn)
            self.read = fn
            if uv.read_start_error then
                return nil, uv.read_start_error
            end
            return 0
        end
        function pipe:close(fn)
            self.closed = true
            driver.defer(fn)
        end
        function pipe:write(data, fn)
            self.written, self.write_done = data, fn
            return true
        end
        function pipe.shutdown(_, fn)
            driver.defer(function()
                fn(nil)
            end)
            return true
        end
        handles[#handles + 1] = pipe
        return pipe
    end
    function uv.spawn(program, spec, on_exit)
        uv.program, uv.spec, uv.exit = program, spec, on_exit
        if uv.spawn_error then
            return nil, uv.spawn_error
        end
        local child = uv.new_pipe()
        function child:kill(signal)
            self.signals = self.signals or {}
            self.signals[#self.signals + 1] = signal
            return 0
        end
        uv.child = child
        return child, 123
    end
    driver.uv = uv
    local runtime = runtimes.new(driver, options)
    local state = { driver = driver, runtime = runtime, uv = uv, handles = handles }
    function state:start(argv, opts)
        self.root = runtime:start(function()
            self.request = process.execute(runtime, argv, opts)
            self.request:on_complete(function(value, err)
                self.value, self.error = value, err
                self.calls = (self.calls or 0) + 1
            end)
        end)
        driver:drain()
        return self.request
    end
    return state
end

function M.test_literal_argv_and_raw_bytes_wait_for_exit_and_both_eofs()
    local f = fixture()
    local argv = { "program", "", "a;b;", "\\$'\"", "line\ncarriage\r", "\255" }
    local req = f:start(argv)
    t.assertEquals(f.uv.program, "program")
    t.assertEquals(f.uv.spec.args, { "", "a;b;", "\\$'\"", "line\ncarriage\r", "\255" })
    f.handles[2].read(nil, "out\000\255")
    f.handles[3].read(nil, "err\r\n")
    f.uv.exit(0, 0)
    f.driver:drain()
    t.assertFalse(req:is_settled())
    f.handles[2].read(nil, nil)
    f.driver:drain()
    t.assertFalse(req:is_settled())
    f.handles[3].read(nil, nil)
    f.driver:drain()
    t.assertEquals(
        f.value,
        { stdout = "out\000\255", stderr = "err\r\n", exit_code = 0, signal = 0 }
    )
    t.assertNil(f.error)
    t.assertEquals(f.calls, 1)
    t.assertTrue(req:is_retired())
    t.assertEquals(f.runtime:stats().active, 0)
end

function M.test_invalid_argv_is_rejected_before_spawn()
    for _, argv in ipairs({ {}, { "" }, { "program", "nul\000byte" }, { "program", false } }) do
        local f = fixture()
        local req = f:start(argv)
        t.assertEquals(f.error.code, "invalid_argv")
        t.assertEquals(f.error.effect, "not_sent")
        t.assertNil(f.uv.program)
        t.assertTrue(req:is_retired())
    end
end

function M.test_eofs_before_nonzero_exit_preserve_partial_output()
    local f = fixture()
    f:start({ "program" })
    f.handles[2].read(nil, "partial")
    f.handles[2].read(nil, nil)
    f.handles[3].read(nil, nil)
    f.driver:drain()
    t.assertFalse(f.request:is_settled())
    f.uv.exit(17, 0)
    f.driver:drain()
    t.assertEquals(f.error.code, "exit_failed")
    t.assertEquals(f.error.effect, "completed")
    t.assertEquals(f.error.partial.stdout, "partial")
    t.assertEquals(f.error.partial.exit_code, 17)
    t.assertEquals(f.calls, 1)
end

function M.test_spawn_failure_closes_allocated_pipes()
    local f = fixture()
    f.uv.spawn_error = "ENOENT"
    f:start({ "missing" })
    t.assertEquals(f.error.code, "spawn_failed")
    t.assertEquals(f.error.cause, "ENOENT")
    t.assertEquals(f.error.effect, "not_sent")
    t.assertTrue(f.request:is_retired())
    for _, handle in ipairs(f.handles) do
        t.assertTrue(handle.closed)
    end
end

function M.test_cancel_settles_before_reaping_without_releasing_active_capacity()
    local f = fixture()
    f:start({ "program" })
    f.request:cancel()
    f.driver:drain()
    t.assertEquals(f.error.code, "cancelled")
    t.assertEquals(f.error.effect, "unknown")
    t.assertFalse(f.request:is_retired())
    t.assertEquals(f.runtime:stats().active, 1)
    t.assertEquals(f.uv.child.signals, { "sigterm" })
    f.driver:advance(100)
    t.assertEquals(f.uv.child.signals, { "sigterm", "sigkill" })
    f.uv.exit(0, 9)
    f.driver:drain()
    t.assertTrue(f.request:is_retired())
    t.assertEquals(f.calls, 1)
    t.assertEquals(f.runtime:stats().active, 0)
end

function M.test_post_exit_drain_deadline_retires_owned_pipes()
    local f = fixture()
    f:start({ "program" }, { drain_timeout = 20 })
    f.handles[2].read(nil, "prefix")
    f.uv.exit(0, 0)
    f.driver:advance(20)
    t.assertEquals(f.error.code, "drain_timeout")
    t.assertEquals(f.error.effect, "completed")
    t.assertEquals(f.error.partial.stdout, "prefix")
    t.assertTrue(f.request:is_retired())
    t.assertNil(f.uv.child.signals)
end

function M.test_output_and_shared_byte_limits_abort_without_retaining_excess()
    for _, shared in ipairs({ false, true }) do
        local f = fixture(shared and { max_bytes = 12 } or nil)
        f:start({ "program" }, { max_output_bytes = shared and 100 or 3 })
        f.handles[2].read(nil, "ab")
        f.handles[3].read(nil, "overflow")
        f.driver:drain()
        t.assertEquals(f.error.code, shared and "queue_full" or "output_limit")
        t.assertEquals(f.error.partial.stdout, "ab")
        t.assertEquals(f.error.partial.stderr, "")
        t.assertEquals(f.error.effect, "unknown")
        t.assertFalse(f.request:is_retired())
        f.uv.exit(0, 15)
        f.driver:drain()
        t.assertTrue(f.request:is_retired())
        t.assertEquals(f.runtime:stats().bytes, 0)
    end
end

function M.test_read_and_write_errors_report_once_and_reap()
    for _, write in ipairs({ false, true }) do
        local f = fixture()
        f:start({ "program" }, write and { stdin = "input" } or nil)
        if write then
            t.assertEquals(f.handles[1].written, "input")
            f.handles[1].write_done("EPIPE")
        else
            f.handles[2].read("EIO", nil)
        end
        f.driver:drain()
        t.assertEquals(f.error.code, write and "write_failed" or "read_failed")
        t.assertEquals(f.error.effect, "unknown")
        f.uv.exit(0, 15)
        f.driver:drain()
        t.assertEquals(f.calls, 1)
        t.assertTrue(f.request:is_retired())
    end
end

function M.test_invalid_caps_and_deadlines_are_rejected_before_spawn()
    for _, options in ipairs({
        { max_output_bytes = false },
        { drain_timeout = false },
        { kill_timeout = false },
        { drain_timeout = 1001 },
        { max_output_bytes = -1 },
    }) do
        local f = fixture()
        f:start({ "program" }, options)
        t.assertNotNil(f.error, "invalid cap must reject before spawn")
        t.assertEquals(f.error.code, "invalid_options")
        t.assertEquals(f.error.effect, "not_sent")
        t.assertNil(f.uv.program)
        t.assertTrue(f.request:is_retired())
    end
end

function M.test_read_start_failure_closes_pipes_and_waits_for_child_reap()
    local f = fixture()
    f.uv.read_start_error = "EBADF"
    f:start({ "program" })
    t.assertEquals(f.error.code, "read_failed")
    t.assertEquals(f.error.cause, "EBADF")
    t.assertFalse(f.request:is_retired())
    f.uv.exit(0, 15)
    f.driver:drain()
    t.assertTrue(f.request:is_retired())
    t.assertEquals(f.calls, 1)
end

function M.test_drain_timer_failure_closes_owned_pipes_without_callback_escape()
    local f = fixture()
    f:start({ "program" })
    f.handles[2].read(nil, "partial")
    local cause = { code = "native_timer_failed", message = "injected allocation failure" }
    rawset(f.driver, "timer", function()
        error(cause)
    end)
    local called = pcall(f.uv.exit, 0, 0)
    t.assertTrue(called, "timer creation failure must not escape the exit callback")
    f.driver:drain()
    t.assertEquals(f.error.code, "timer_failed")
    t.assertIs(f.error.cause, cause)
    t.assertEquals(f.error.effect, "completed")
    t.assertEquals(f.error.partial.stdout, "partial")
    t.assertTrue(f.request:is_retired())
    t.assertEquals(f.calls, 1)
    t.assertEquals(f.runtime:stats().active, 0)
    for _, handle in ipairs(f.handles) do
        t.assertTrue(handle.closed)
    end
end

function M.test_cancellation_timer_failure_escalates_owned_client_and_reports_cleanup()
    local f = fixture()
    f:start({ "program" })
    local cause = { code = "native_timer_failed", message = "injected allocation failure" }
    rawset(f.driver, "timer", function()
        error(cause)
    end)
    t.assertTrue(f.request:cancel())
    f.driver:drain()
    t.assertEquals(f.uv.child.signals, { "sigterm", "sigkill" })
    t.assertEquals(f.error.code, "cancelled")
    t.assertFalse(f.request:is_retired())
    t.assertEquals(f.runtime:stats().active, 1)
    for index = 1, 3 do
        t.assertTrue(f.handles[index].closed)
    end
    f.uv.exit(0, 9)
    f.driver:drain()
    t.assertTrue(f.request:is_retired())
    t.assertEquals(f.calls, 1)
    t.assertEquals(f.runtime:stats().active, 0)
    local cleanup = f.runtime:errors()
    t.assertEquals(#cleanup, 1)
    t.assertEquals(cleanup[1].code, "cleanup_failed")
    t.assertIs(cleanup[1].cause, cause)
end

function M.test_false_options_are_rejected_before_spawn()
    local f = fixture()
    f:start({ "program" }, false)
    t.assertNotNil(f.error, "false options must reject before spawn")
    t.assertEquals(f.error.code, "invalid_options")
    t.assertEquals(f.error.effect, "not_sent")
    t.assertNil(f.uv.program)
end

function M.test_metatables_are_rejected_without_metamethods()
    local touched = false
    local function touch()
        touched = true
        error("must not invoke input metamethods")
    end
    local metatable = { __len = touch, __pairs = touch, __index = touch }
    local cases = {
        { argv = setmetatable({ "program" }, metatable), code = "invalid_argv" },
        { argv = { "program" }, options = setmetatable({}, metatable), code = "invalid_options" },
        {
            argv = { "program" },
            options = { env = setmetatable({ "KEY=value" }, metatable) },
            code = "invalid_options",
        },
    }
    for _, case in ipairs(cases) do
        local f = fixture()
        f:start(case.argv, case.options)
        t.assertNotNil(f.error, "invalid plain-data arguments must reject before spawn")
        t.assertEquals(f.error.code, case.code)
        t.assertEquals(f.error.effect, "not_sent")
        t.assertFalse(touched)
        t.assertNil(f.uv.program)
        t.assertTrue(f.request:is_retired())
    end
end

function M.test_timer_cancellation_failure_preserves_result_and_retirement()
    local f = fixture()
    f:start({ "program" })
    local cause = { code = "native_close_failed", message = "injected close failure" }
    local timer = f.driver.timer
    rawset(f.driver, "timer", function(delay, callback)
        local cancel = timer(delay, callback)
        return function()
            cancel()
            error(cause)
        end
    end)
    f.uv.exit(0, 0)
    f.handles[2].read(nil, nil)
    local called = pcall(f.handles[3].read, nil, nil)
    t.assertTrue(called, "timer cancellation must not escape the EOF callback")
    f.driver:drain()
    t.assertNil(f.error)
    t.assertEquals(f.value.exit_code, 0)
    t.assertTrue(f.request:is_retired())
    t.assertEquals(f.calls, 1)
    t.assertEquals(f.runtime:stats().active, 0)
    local cleanup = f.runtime:errors()
    t.assertEquals(#cleanup, 1)
    t.assertEquals(cleanup[1].code, "cleanup_failed")
    t.assertIs(cleanup[1].cause, cause)
end

return M
