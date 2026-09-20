local t = require("luaunit")
local drivers = require("tests.support.runtime_driver")
local available, transport = pcall(require, "libtmux._internal.control_io")
local M = {}

local function fixture()
    t.assertTrue(available, "persistent control byte transport is missing")
    local driver = drivers.new()
    local uv = { pipes = {}, signals = {} }
    function uv.new_pipe()
        local pipe = {}
        uv.pipes[#uv.pipes + 1] = pipe
        function pipe:read_start(fn)
            self.read = fn
            return true
        end
        function pipe:write(data, fn)
            self.written, self.write_done = data, fn
            return true
        end
        function pipe:close(fn)
            self.closed = true
            driver.defer(fn)
        end
        return pipe
    end
    function uv.spawn(program, options, exit)
        uv.program, uv.options, uv.exit = program, options, exit
        local child = {}
        function child:close(fn)
            self.closed = true
            driver.defer(fn)
        end
        function child.kill(_, signal)
            uv.signals[#uv.signals + 1] = signal
            return true
        end
        uv.child = child
        return child, 101
    end
    driver.uv = uv
    local f = { driver = driver, uv = uv, data = {}, endings = {} }
    f.io = assert(transport.start({ _driver = driver }, {
        binary = "/actual/tmux",
        socket = "/owned/pin/socket",
        config = "/dev/null",
    }, { session_id = "$0" }, function(data)
        f.data[#f.data + 1] = data
    end, function(err)
        f.endings[#f.endings + 1] = { err = err }
        if uv.close_in_end then
            f.io:close(uv.close_in_end)
        end
        if uv.throw_end then
            error("terminal observer failed")
        end
    end))
    return f
end

function M.test_literal_control_spawn_keeps_reader_alive_until_exit_and_both_eofs()
    local f = fixture()
    t.assertEquals(f.uv.program, "/actual/tmux")
    t.assertEquals(f.uv.options.args, {
        "-N",
        "-S",
        "/owned/pin/socket",
        "-u",
        "-f",
        "/dev/null",
        "-C",
        "attach-session",
        "-E",
        "-f",
        "ignore-size,active-pane",
        "-t",
        "$0",
    })
    f.uv.pipes[2].read(nil, "bytes\000\255")
    f.uv.exit(0, 0)
    f.driver:drain()
    t.assertEquals(f.endings, {})
    f.uv.pipes[2].read(nil, nil)
    f.driver:drain()
    t.assertEquals(f.endings, {})
    f.uv.pipes[3].read(nil, nil)
    f.driver:drain()
    t.assertEquals(f.data, { "bytes\000\255" })
    t.assertEquals(#f.endings, 1)
    t.assertNil(f.endings[1].err)
    local closed = false
    f.io:close(function(err)
        t.assertNil(err)
        closed = true
    end)
    t.assertTrue(closed)
end

function M.test_stdout_eof_before_exit_reports_loss_and_retains_native_ownership()
    local f = fixture()
    local closed, write_error
    f.uv.close_in_end = function(err)
        t.assertNil(err)
        closed = true
    end
    assert(f.io:write("command\n", function(err)
        write_error = err
    end))
    f.uv.pipes[3].read(nil, nil)
    f.driver:drain()
    t.assertEquals(f.endings, {})
    f.uv.pipes[2].read(nil, nil)
    t.assertEquals(#f.endings, 1)
    t.assertEquals(f.endings[1].err.code, "unexpected_eof")
    t.assertEquals(f.uv.signals, { "sigterm" })
    f.driver:drain()
    t.assertNil(closed)
    t.assertNil(f.uv.child.closed)
    f.driver:advance(100)
    t.assertEquals(f.uv.signals, { "sigterm", "sigkill" })
    f.uv.exit(0, 9)
    f.driver:drain()
    t.assertNil(closed)
    f.uv.pipes[1].write_done("ECANCELED")
    f.driver:drain()
    t.assertNotNil(write_error)
    t.assertTrue(closed)
    t.assertTrue(f.uv.child.closed)
    t.assertEquals(#f.endings, 1)
end

function M.test_close_waits_for_pending_write_and_owned_client_reaping()
    local f = fixture()
    local write_error, closed
    assert(f.io:write("command\n", function(err)
        write_error = err
    end))
    f.io:close(function(err)
        t.assertNil(err)
        closed = true
    end)
    f.driver:advance(100)
    t.assertEquals(f.uv.signals, { "sigterm" })
    f.driver:advance(100)
    t.assertEquals(f.uv.signals, { "sigterm", "sigkill" })
    f.uv.exit(0, 0)
    f.uv.pipes[2].read(nil, nil)
    f.uv.pipes[3].read(nil, nil)
    f.driver:drain()
    t.assertNil(closed)
    f.uv.pipes[1].write_done("ECANCELED")
    f.driver:drain()
    t.assertNotNil(write_error)
    t.assertTrue(closed)
end

function M.test_post_exit_open_pipe_reports_incomplete_drain_and_closes_handles()
    local f = fixture()
    f.uv.exit(0, 0)
    f.driver:advance(250)
    f.driver:drain()
    t.assertEquals(#f.endings, 1)
    t.assertEquals(f.endings[1].err.code, "drain_timeout")
    for _, pipe in ipairs(f.uv.pipes) do
        t.assertTrue(pipe.closed)
    end
    t.assertTrue(f.uv.child.closed)
end

function M.test_private_callback_faults_do_not_escape_or_abandon_native_cleanup()
    local f = fixture()
    local closed, cleanup_error
    f.uv.throw_end = true
    assert(f.io:write("command\n", function()
        error("write observer failed")
    end))
    f.io:close(function(err)
        closed, cleanup_error = true, err
    end)
    f.uv.pipes[1].write_done()
    f.uv.exit(0, 0)
    f.uv.pipes[2].read(nil, nil)
    f.uv.pipes[3].read(nil, nil)
    f.driver:drain()
    t.assertTrue(closed)
    t.assertEquals(assert(cleanup_error).code, "cleanup_failed")
end

function M.test_reentrant_close_from_terminal_observer_notifies_native_cleanup_once()
    local f = fixture()
    local count, cleanup_error = 0, nil
    f.uv.throw_end = true
    f.uv.close_in_end = function(err)
        count, cleanup_error = count + 1, err
    end
    f.uv.exit(0, 0)
    f.uv.pipes[2].read(nil, nil)
    f.uv.pipes[3].read(nil, nil)
    f.driver:drain()
    t.assertEquals(count, 1)
    t.assertEquals(assert(cleanup_error).code, "cleanup_failed")
end

return M
