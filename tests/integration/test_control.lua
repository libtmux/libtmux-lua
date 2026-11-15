-- Persistent observations against an explicitly owned tmux session.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

local TOPOLOGY = "#{session_id};#{pane_id};#{window_id};#{window_width};#{window_height}"

local function split(text)
    local found = {}
    for field in (text .. ";"):gmatch("(.-);") do
        found[#found + 1] = field
    end
    return found
end

local function after_first(fields)
    return { unpack(fields, 2) }
end

local function run_case(case, host, timeout)
    fixture.with(function(f)
        fixture.require_control(f)
        f:run("resize-window", "-t", "fixture:0", "-x", "121", "-y", "37")
        local before = f:out("display-message", "-p", "-t", "fixture:0.0", TOPOLOGY)
        local session, pane, window = unpack(split(before:gsub("%s+$", "")))
        local extra = {
            LC_ALL = "C",
            LANG = "C",
            TMUX_TEST_SESSION = session,
            TMUX_TEST_PANE = pane,
            LIBTMUX_CONTROL_CASE = case,
        }
        if case == "unlink" then
            f:run("new-window", "-d", "-t", session, "exec /bin/cat")
            local unrelated = f:out(
                "new-session",
                "-d",
                "-s",
                "survivor",
                "-P",
                "-F",
                "#{window_id}",
                "exec /bin/cat"
            ):gsub("%s+$", "")
            f:run("link-window", "-d", "-s", window, "-t", "survivor:1")
            extra.TMUX_TEST_WINDOW, extra.TMUX_TEST_UNRELATED_WINDOW = window, unrelated
        end
        if case == "missing" then
            f:run("set-option", "-s", "exit-empty", "off")
            f:run("kill-session", "-t", session)
        end
        local result = f:program(host, "control", extra, { timeout = timeout })
        test.assertStrContains(result.stdout, "control observation passed")
        if case == "missing" then
            test.assertEquals(f:out("list-sessions"), "")
        elseif case == "unlink" then
            local remaining = f:out("list-panes", "-s", "-t", session, "-F", "#{pane_id}")
            test.assertNil(("\n" .. remaining):find("\n" .. pane .. "\n", 1, true))
            local after = f:out("display-message", "-p", "-t", pane, TOPOLOGY)
            test.assertEquals(after_first(split(after)), after_first(split(before)))
            test.assertEquals(f:out("list-clients"), "")
        else
            test.assertEquals(f:out("display-message", "-p", "-t", "fixture:0.0", TOPOLOGY), before)
            test.assertEquals(f:out("list-clients"), "")
        end
    end)
end

fixture.each_host(M, "ready_observation_bytes_overflow_and_explicit_teardown", function(host)
    run_case("stream", host)
end)
fixture.each_host(M, "missing_session_does_not_create_a_scratch_session", function(host)
    run_case("missing", host)
end)
fixture.each_host(
    M,
    "unlinked_window_reports_loss_without_unrelated_window_false_gap",
    function(host)
        run_case("unlink", host)
    end
)
-- slow: tmux samples native format subscriptions once per second.
fixture.each_host(M, "slow_native_format_subscription_delivers_typed_context", function(host)
    run_case("format", host, 1.8)
end)

return M
