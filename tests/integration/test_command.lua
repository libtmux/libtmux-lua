-- Real tmux argv encoding, command-group boundaries and WAIT completion.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local shell = require("support.shell")
local M = {}

local function run_case(case, host)
    fixture.with(function(f)
        local base = { f.binary, "-S", f.socket, "wait-for" }
        local function wait_for(...)
            local argv = { unpack(base) }
            for _, word in ipairs({ ... }) do
                argv[#argv + 1] = word
            end
            return shell.join(argv)
        end
        local script = table.concat({
            wait_for("-S", "libtmux-command-ready"),
            wait_for("libtmux-command-release"),
            "printf 'late output\\n'",
            "exit 7",
        }, "; ")
        local result = f:program(host, "command", {
            LIBTMUX_COMMAND_CASE = case,
            LIBTMUX_WAIT_SHELL = script,
        })
        test.assertStrContains(result.stdout, case .. " passed")
    end)
end

fixture.each_host(M, "literal_argv_roundtrip", function(host)
    run_case("literal", host)
end)
fixture.each_host(M, "group_parse_and_runtime_errors", function(host)
    run_case("group", host)
end)
fixture.each_host(M, "wait_finishes_after_release_and_failure", function(host)
    run_case("wait", host)
end)

function M.test_control_guard_precedes_wait_completion()
    fixture.with(function(f)
        local wait = shell.join({ f.binary, "-S", f.socket, "wait-for", "libtmux-control-release" })
        local script = wait .. "; printf 'guard-late-output\\n'; exit 7"
        local client = f:spawn({
            "-C",
            "run-shell",
            "-t",
            "fixture:0.0",
            script,
            ";",
            "display-message",
            "-p",
            "GUARD_WAIT_CONTINUED",
        }, { stdin = "pipe" })
        test.assertTrue(
            client:expect(function(fresh)
                return fresh:find("\n%end ", 1, true) ~= nil
            end, fixture.DEADLINE),
            client:output()
        )
        test.assertNil(client:output():find("GUARD_WAIT_CONTINUED", 1, true))
        test.assertFalse(client.exited)
        f:run("wait-for", "-S", "libtmux-control-release")
        test.assertTrue(client:wait(0.8), client:output())
        test.assertEquals(client.code, 7, client:errors())
        test.assertStrContains(client:output(), "GUARD_WAIT_CONTINUED\n%end ")
    end)
end

return M
