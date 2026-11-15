-- Real tmux ownership and cleanup checks.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local repo = require("support.repo")
local uv = require("support.uv")
local M = {}

--- A function that tells whether the process is gone.
local function observe(pid)
    return function()
        return not child.alive(pid)
    end
end

local function assert_removed(f, exited)
    test.assertNil(fs.stat(f.socket))
    test.assertNil(fs.stat(f.path))
    for name, gone in pairs(exited) do
        test.assertTrue(gone(), ("owned %s process did not exit"):format(name))
    end
end

function M.test_success_cleanup_preserves_another_owned_server()
    local borrowed_path
    fixture.with(function(borrowed)
        borrowed_path = borrowed.path
        uv.os_setenv("TMUX", borrowed.socket)
        uv.os_setenv("TMUX_PANE", "%999")
        local owned, client, exited
        local ok, failure = pcall(fixture.with, function(o)
            owned = o
            test.assertNotEquals(o.socket, borrowed.socket)
            test.assertStrMatches(o.path, "/tmp/libtmux%-lua%-.*")
            test.assertTrue(#o.socket < 100)
            test.assertNil(o.env.TMUX)
            test.assertNil(o.env.TMUX_PANE)
            test.assertEquals(uv.fs_stat(o.path).mode % 512, 448)
            test.assertEquals(
                o:out("display-message", "-p", "#{socket_path}"):gsub("%s+$", ""),
                o.socket
            )
            client = o:spawn({ "wait-for", "never-signalled" })
            exited = {
                server = observe(o.server_pid),
                pane = observe(o.pane_pids[1]),
                client = observe(client.pid),
            }
        end)
        -- The decoys must not outlive this test, whatever the fixture did with them.
        uv.os_unsetenv("TMUX")
        uv.os_unsetenv("TMUX_PANE")
        if not ok then
            error(failure, 0)
        end
        assert_removed(owned, exited)
        test.assertTrue(client.exited)
        test.assertEquals(borrowed:try("has-session", "-t", "fixture").code, 0)
    end)
    test.assertNil(fs.stat(borrowed_path))
end

function M.test_exception_and_cancellation_cleanup()
    for _, failure in ipairs({ "injected fixture exit", child.CANCELLED }) do
        local owned, exited
        local ok, raised = pcall(fixture.with, function(o)
            owned = o
            exited = { server = observe(o.server_pid), pane = observe(o.pane_pids[1]) }
            error(failure, 0)
        end)
        test.assertFalse(ok)
        test.assertEquals(raised, failure)
        assert_removed(owned, exited)
    end
end

function M.test_requiring_the_harness_starts_no_process_and_creates_no_directory()
    local probe = ([[
        package.path = %q
        require("support.repo").use_rocks()
        local uv = require("support.uv")
        for _, name in ipairs({ "spawn", "fs_mkdtemp" }) do
            uv[name] = function()
                error("requiring the harness used uv." .. name)
            end
        end
        require("tests.support.child")
        require("tests.support.fixture")
    ]]):format(package.path)
    local result = child.run({ fixture.luajit(), "-e", probe }, { timeout = 3 })
    test.assertEquals(result.code, 0, result.stderr)
end

function M.test_cleanup_failures_still_release_owned_resources()
    fixture.with(function(borrowed)
        for _, failed in ipairs({ { "list-panes" }, { "list-panes", "kill-server" } }) do
            local owned = fixture.new()
            owned:open()
            local client = owned:spawn({ "wait-for", "never-signalled" })
            local exited = {
                server = observe(owned.server_pid),
                pane = observe(owned.pane_pids[1]),
                client = observe(client.pid),
            }
            local real = owned.try
            owned.try = function(self, command, ...)
                for _, name in ipairs(failed) do
                    if command == name then
                        error("timed out: " .. command, 0)
                    end
                end
                return real(self, command, ...)
            end
            local ok, failure = pcall(owned.close, owned)
            test.assertFalse(ok)
            test.assertStrContains(failure, "tmux fixture cleanup failed")
            for _, name in ipairs(failed) do
                test.assertStrContains(failure, name)
            end
            assert_removed(owned, exited)
            test.assertFalse(client.out_open or client.err_open)
            test.assertEquals(borrowed:try("has-session", "-t", "fixture").code, 0)
        end
    end)
end

function M.test_reaped_client_pipes_close()
    local client
    fixture.with(function(owned)
        client = owned:spawn({ "display-message", "-p", "ready" })
        test.assertTrue(client:wait(fixture.DEADLINE))
        test.assertEquals(client:output(), "ready\n")
    end)
    test.assertFalse(client.out_open or client.err_open)
end

function M.test_sigterm_unwinds_fixture_in_worker()
    local worker = child.spawn(
        { fixture.luajit(), repo.root .. "/tests/support/programs/worker.lua" },
        {}
    )
    local path, socket, server, pane
    local ok, failure = pcall(function()
        test.assertTrue(
            worker:expect(function(fresh)
                return select(2, fresh:gsub("\n", "")) >= 4
            end, fixture.DEADLINE),
            worker:errors()
        )
        local lines = {}
        for line in worker:output():gmatch("[^\n]+") do
            lines[#lines + 1] = line
        end
        path, socket, server, pane = lines[1], lines[2], tonumber(lines[3]), tonumber(lines[4])
        worker:kill("sigterm")
        test.assertTrue(worker:wait(fixture.DEADLINE), worker:errors())
        test.assertEquals(worker.code, 143, worker:errors())
        test.assertNil(fs.stat(path))
        test.assertTrue(observe(server)(), "owned server survived SIGTERM")
        test.assertTrue(observe(pane)(), "owned pane survived SIGTERM")
    end)
    worker:close()
    if socket and fs.stat(socket) then
        child.run(
            { fixture.tmux(), "-f", "/dev/null", "-S", socket, "kill-server" },
            { timeout = 1 }
        )
    end
    if path then
        fs.remove_tree(path)
    end
    if not ok then
        error(failure, 0)
    end
end

return M
