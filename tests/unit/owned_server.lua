local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local M = {}

-- A driver whose uv records every filesystem and spawn call. start_server must
-- refuse a bad request before it touches any of them.
local function fixture(sysname, tmpdir)
    local driver = drivers.new()
    local uv = { calls = {} }
    function uv.os_uname()
        return { sysname = sysname or "Linux" }
    end
    function uv.os_tmpdir()
        return tmpdir or "/tmp"
    end
    function uv.os_environ()
        return { PATH = "/usr/bin" }
    end
    function uv.fs_mkdtemp(template)
        uv.calls[#uv.calls + 1] = { "fs_mkdtemp", template }
        return nil, "EACCES: permission denied"
    end
    function uv.spawn()
        uv.calls[#uv.calls + 1] = { "spawn" }
        return nil, "EACCES"
    end
    function uv.new_pipe()
        uv.calls[#uv.calls + 1] = { "new_pipe" }
        return nil, "EMFILE"
    end
    driver.uv = uv
    local runtime = runtimes.new(driver)
    local f = { runtime = runtime, driver = driver, uv = uv }
    function f.run(fn)
        local root = runtime:start(fn)
        driver:drain()
        t.assertTrue(root:is_settled())
        local _, err = root:result()
        t.assertNil(err)
    end
    return f
end

local function start(rt, options)
    return rt:start_server(options):await()
end

function M.test_runtime_offers_the_owned_server_entry_points()
    local f = fixture()
    f.run(function(rt)
        t.assertEquals(type(rt.start_server), "function")
        t.assertEquals(type(rt.with_server), "function")
    end)
end

function M.test_rejects_malformed_options_before_any_effect()
    local f = fixture()
    f.run(function(rt)
        for _, case in ipairs({
            { nil, "invalid_options" },
            { false, "invalid_options" },
            { {}, "invalid_endpoint" },
            { { binary = "tmux" }, "invalid_endpoint" },
            { { binary = "/bin/tmux", config = "relative" }, "invalid_endpoint" },
            { { binary = "/bin/tmux", root = "relative" }, "invalid_endpoint" },
            { { binary = "/bin/tmux", unknown = true }, "invalid_options" },
            { { binary = "/bin/tmux", timeout = 0 }, "invalid_options" },
            { { binary = "/bin/tmux", timeout = 1.5 }, "invalid_options" },
            { { binary = "/bin/tmux", environment = "PATH=/bin" }, "invalid_options" },
            { { binary = "/bin/tmux", environment = { [1] = "x" } }, "invalid_options" },
            { { binary = "/bin/tmux", environment = { ["A=B"] = "x" } }, "invalid_options" },
            { { binary = "/bin/tmux", environment = { A = 1 } }, "invalid_options" },
            { { binary = "/bin/tmux", environment = { A = "x\0y" } }, "invalid_options" },
            { { binary = "/bin/tmux", environment = { TMUX = "x" } }, "invalid_options" },
            { { binary = "/bin/tmux", environment = { TMUX_PANE = "x" } }, "invalid_options" },
            { { binary = "/bin/tmux", environment = { TMUX_TMPDIR = "/x" } }, "invalid_options" },
            {
                { binary = "/bin/tmux", environment = { LIBTMUX_SOCKET_NAME = "x" } },
                "invalid_options",
            },
        }) do
            local value, err = start(rt, case[1])
            t.assertNil(value)
            t.assertEquals(err.code, case[2], tostring(case[2]))
            t.assertEquals(err.effect, "not_sent")
        end
    end)
    t.assertEquals(f.uv.calls, {})
end

-- The longest path libtmux makes under the directory is the socket alias that
-- pins a connection: root/libtmux-XXXXXX/libtmux-lua-pin-XXXXXX/socket.
local ALIAS_BYTES = #"/libtmux-XXXXXX" + #"/libtmux-lua-pin-XXXXXX" + #"/socket"

function M.test_a_root_that_leaves_no_room_for_a_socket_path_is_refused_by_platform()
    for _, case in ipairs({
        { "Linux", 108 },
        { "Darwin", 104 },
        { "FreeBSD", 104 },
    }) do
        local sysname, limit = case[1], case[2]
        local fits = limit - 1 - ALIAS_BYTES
        local f = fixture(sysname)
        f.run(function(rt)
            local over = "/" .. ("r"):rep(fits)
            local value, err = start(rt, { binary = "/bin/tmux", root = over })
            t.assertNil(value, sysname)
            t.assertEquals(err.code, "invalid_endpoint", sysname)
            t.assertEquals(err.effect, "not_sent")
            t.assertNotNil(err.message:find("socket path", 1, true))
            t.assertEquals(f.uv.calls, {}, sysname)

            local exact = "/" .. ("r"):rep(fits - 1)
            value, err = start(rt, { binary = "/bin/tmux", root = exact })
            t.assertNil(value, sysname)
            t.assertEquals(err.code, "filesystem_error", sysname)
            t.assertEquals(f.uv.calls[1], { "fs_mkdtemp", exact .. "/libtmux-XXXXXX" }, sysname)
        end)
    end
end

function M.test_the_default_root_is_the_system_temp_directory_or_tmp_when_that_is_too_long()
    for _, case in ipairs({
        { "/var/tmp-short", "/var/tmp-short" },
        { "/" .. ("t"):rep(120), "/tmp" },
    }) do
        local f = fixture("Linux", case[1])
        f.run(function(rt)
            local value, err = start(rt, { binary = "/bin/tmux" })
            t.assertNil(value)
            t.assertEquals(err.code, "filesystem_error")
            t.assertEquals(f.uv.calls[1], { "fs_mkdtemp", case[2] .. "/libtmux-XXXXXX" })
        end)
    end
end

function M.test_a_failed_directory_names_the_operation_and_cause()
    local f = fixture()
    f.run(function(rt)
        local _, err = start(rt, { binary = "/bin/tmux", root = "/owned" })
        t.assertEquals(err.operation, "start_server")
        t.assertEquals(err.effect, "not_sent")
        t.assertNotNil(tostring(err.cause):find("EACCES", 1, true))
        t.assertEquals(#f.uv.calls, 1, "no tmux was spawned without a directory")
    end)
end

return M
