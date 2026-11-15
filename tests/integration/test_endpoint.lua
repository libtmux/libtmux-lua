-- Pinned daemon generations use owned aliases and never silently reconnect.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local uv = require("support.uv")
local M = {}

local function run_case(mode, host)
    fixture.with(function(f)
        local version = f:version()
        local program = f:start_program(
            host,
            "endpoint",
            { TMUX_DAEMON_VERSION = version, LIBTMUX_ENDPOINT_CASE = mode },
            "pipe"
        )
        local old_socket = f.path .. "/old.sock"
        local ok, failure = pcall(function()
            if mode == "replacement" or mode == "dead" then
                test.assertTrue(
                    program:expect(function(fresh)
                        return fresh:find("\n", 1, true) ~= nil
                    end, fixture.DEADLINE),
                    program:errors()
                )
                local ready = program:output():match("^[^\n]*")
                local old_pid, old_started = ready:match("^READY (%d+) (%d+)$")
                test.assertNotNil(old_pid, ready .. program:errors())
                if mode == "replacement" then
                    assert(uv.fs_rename(f.socket, old_socket))
                    local result = f:run(
                        "new-session",
                        "-d",
                        "-s",
                        "fixture",
                        "-P",
                        "-F",
                        "#{pid} #{pane_pid}",
                        "exec /bin/cat"
                    )
                    f:record_panes(result.stdout)
                    test.assertNotEquals(tostring(f.server_pid), old_pid)
                    test.assertEquals(
                        f:out("display-message", "-p", "#{session_id} #{pane_id}"),
                        "$0 %0\n"
                    )
                    test.assertNotNil(old_started)
                else
                    f:run("kill-server")
                    f:wait_exits()
                end
                program:write("continue\n")
            end
            local result = program:finish(fixture.DEADLINE)
            test.assertEquals(result.code, 0, result.stderr)
            test.assertStrContains(result.stdout, mode .. " passed")
            test.assertEquals(f:pins(), {})
            if mode == "replacement" then
                test.assertEquals(f:out("list-sessions", "-F", "#{session_name}"), "fixture\n")
            elseif mode == "dead" then
                test.assertNotEquals(f:try("list-sessions").code, 0)
            end
        end)
        program:close()
        if fs.stat(old_socket) then
            child.run({ f.binary, "-N", "-S", old_socket, "kill-server" }, { env = f.env })
        end
        if not ok then
            error(failure, 0)
        end
    end)
end

fixture.each_host(M, "actual_daemon_evidence_and_explicit_close", function(host)
    run_case("normal", host)
end)
fixture.each_host(M, "path_replacement_rejects_reused_entity_ids", function(host)
    run_case("replacement", host)
end)
fixture.each_host(M, "dead_alias_cannot_autostart_new_daemon", function(host)
    run_case("dead", host)
end)
fixture.each_host(M, "late_cancelled_binding_allocation_is_removed", function(host)
    run_case("cancel_bind", host)
end)

return M
