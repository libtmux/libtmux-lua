-- Unsafe optional tmux features are refused before they reach the daemon.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

local DEADLINE = 3

local function run_lua(f, version, case, host, argv)
    local words = {}
    for _, word in ipairs(argv or {}) do
        words[#words + 1] = word .. "|"
    end
    local result = f:program(host, "features", {
        TMUX_DAEMON_VERSION = version,
        LIBTMUX_FEATURE_CASE = case,
        LIBTMUX_FEATURE_ARGV = table.concat(words),
    }, { timeout = DEADLINE })
    local report = result.stdout:match("FEATURE ([^\n]*)")
    test.assertNotNil(report, result.stdout)
    return report
end

local function alive(f)
    test.assertEquals(f:try("list-sessions", "-F", "#{session_name}").code, 0)
end

--- Everything a refused command must leave alone.
local function state(f)
    return {
        f:out("list-buffers", "-F", "#{buffer_name}"),
        f:out("list-windows", "-a", "-F", "#{window_id}"),
        f:out("list-panes", "-a", "-F", "#{pane_id}"),
        f:out("list-sessions", "-F", "#{session_name}"),
    }
end

fixture.each_host(M, "control_observation_needs_tmux_3_7_and_attaches_nothing_below", function(host)
    fixture.with(function(f)
        local version = f:version()
        local report = run_lua(f, version, "observe", host)
        local clients = f:out("list-clients", "-F", "#{client_control_mode}")
        if not fixture.at_least(version, 3, 7) then
            test.assertEquals(report, "REFUSED unsupported 3.7 not_sent")
        else
            test.assertEquals(report, "RAN")
        end
        -- Observation closed or never attached: no control client remains.
        test.assertEquals(clients, "")
        alive(f)
    end)
end)

fixture.each_host(M, "raw_commands_are_refused_per_release_without_effects", function(host)
    fixture.with(function(f)
        local version = f:version()
        local older = function(major, minor)
            return not fixture.at_least(version, major, minor)
        end
        f:run("split-window", "-d", "-t", "$0", "exec /bin/cat")
        f:run("set-buffer", "-b", "keep", "sentinel")
        f:run("set-buffer", "-b", "spare", "renamable")
        local cases = {
            -- tmux 3.3a exits its daemon on a layout whose first character is not a hex digit;
            -- "bogus" is an ordinary error there.
            { "invalid layout", { "select-layout", "-t", "@0", "x" }, older(3, 4) },
            { "empty layout", { "select-layout", "-t", "@0", "" }, older(3, 4) },
            { "preset layout", { "select-layout", "-t", "@0", "tiled" }, false },
            { "named buffer delete", { "delete-buffer", "-b", "absent-name" }, older(3, 4) },
            { "buffer rename", { "set-buffer", "-b", "spare", "-n", "spare2" }, older(3, 4) },
            {
                "split percent",
                { "split-window", "-d", "-t", "@0", "-p", "40", "exec /bin/cat" },
                version == "3.4",
            },
            { "break pane", { "break-pane", "-d", "-s", "%1" }, version == "3.7" },
            -- With an attached xterm-256color client, 3.3a stops on -l, and 3.4 through 3.6 stop
            -- when that client leaves unanswered. The releases are written out so moving the
            -- registry fails this.
            {
                "clipboard query",
                { "refresh-client", "-l" },
                version == "3.3a"
                    or version == "3.4"
                    or version == "3.5"
                    or version == "3.5a"
                    or version == "3.6",
            },
            {
                "dotted session",
                { "new-session", "-d", "-s", "dot.name", "exec /bin/cat" },
                version == "3.7",
            },
        }
        for _, case in ipairs(cases) do
            local label, argv, refused = case[1], case[2], case[3]
            local before = state(f)
            local report = run_lua(f, version, "raw", host, argv)
            local after = state(f)
            alive(f)
            if refused then
                test.assertStrMatches(
                    report,
                    "REFUSED unsupported.*",
                    nil,
                    nil,
                    label .. ": " .. report
                )
                test.assertEquals(after, before, label)
            else
                test.assertEquals(report:sub(1, 3), "RAN", label .. ": " .. report)
            end
            -- The sentinel survives every case, including the refused delete.
            test.assertStrContains(after[1], "keep")
        end
    end)
end)

return M
