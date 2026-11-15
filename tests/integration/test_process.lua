-- Owned-client PROCESS integration against real luv, Neovim and tmux.
local test = require("luaunit")
local child = require("tests.support.child")
local files = require("support.files")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local uv = require("support.uv")
local M = {}

local function run_case(case, host, env)
    env = fixture.environment(env)
    env.LIBTMUX_PROCESS_CASE = case
    return fixture.program(host, "process", env).stdout
end

fixture.each_host(M, "literal_bytes_exit_and_spawn_errors", function(host)
    test.assertStrContains(run_case("bytes", host), "bytes passed")
end)

fixture.each_host(M, "live_tmux_cancellation_preserves_server_and_other_progress", function(host)
    fixture.with(function(f)
        local env = f:program_env()
        test.assertStrContains(run_case("tmux", host, env), "tmux passed")
        test.assertEquals(f:try("has-session", "-t", "fixture").code, 0)
    end)
end)

fixture.each_host(M, "post_exit_drain_leaves_descendant_for_its_owner", function(host)
    local directory = fs.mkdtemp("libtmux-lua-process-")
    local fifo, pidfile = directory .. "/release", directory .. "/descendant.pid"
    child.mkfifo(fifo)
    local pid
    local ok, failure = pcall(function()
        local result = run_case("drain", host, {
            LIBTMUX_RELEASE_FIFO = fifo,
            LIBTMUX_DESCENDANT_PID = pidfile,
        })
        pid = tonumber(result:match("descendant (%d+)"))
        test.assertNotNil(pid, result)
        test.assertEquals(pid, tonumber(files.read(pidfile)))
        test.assertTrue(child.alive(assert(pid)), "the descendant did not outlive its parent")
    end)
    -- Release the descendant whatever happened, and prove it goes.
    local release = assert(uv.fs_open(fifo, "r+", 448))
    uv.fs_write(release, "x")
    uv.fs_close(release)
    if not pid and fs.stat(pidfile) then
        pid = tonumber(files.read(pidfile))
    end
    local left = pid and child.wait_gone({ pid }, fixture.DEADLINE) or {}
    if #left > 0 then
        uv.kill(pid, "sigkill")
    end
    fs.remove_tree(directory)
    if not ok then
        error(failure, 0)
    end
    test.assertEquals(left, {}, "owned descendant failed to exit after FIFO release")
end)

return M
