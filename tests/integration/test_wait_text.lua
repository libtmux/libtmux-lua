-- Pane:wait_for_text polls the visible screen on every tmux release.
local test = require("luaunit")
local child = require("tests.support.child")
local files = require("support.files")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local repo = require("support.repo")
local M = {}

local LIMIT = 30

local function start(f, host, case)
    return f:start_program(host, "wait_text", {
        LIBTMUX_OUTPUT_SCRIPT = repo.root .. "/tests/support/programs/output.lua",
        LIBTMUX_WAIT_CASE = case,
        LIBTMUX_WAIT_DIR = f.path,
    })
end

local function finish(program, case, limit)
    local result = program:finish(limit or LIMIT)
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout, "wait text PASS " .. case)
end

--- The size of a file the program's hooks append to, once it has settled: the same size twice,
--- 0.2 s apart, and at least `expected` when given.
local function counter(f, name, expected)
    local path = f.path .. "/" .. name
    local function size()
        local stat = fs.stat(path)
        return stat and stat.size or 0
    end
    local deadline = os.time() + 3
    local previous = -1
    while os.time() < deadline do
        local current = size()
        if current == previous and (expected == nil or current >= expected) then
            break
        end
        previous = current
        child.sleep(0.2)
    end
    return size()
end

local function run_case(case, host, check, setup, limit)
    fixture.with(function(f)
        if setup then
            setup(f)
        end
        local version = f:version()
        finish(start(f, host, case), case, limit)
        test.assertEquals(f:pins(), {})
        if check then
            check(f, version)
        end
    end)
end

local function register(name, case, check, setup, limit)
    fixture.each_host(M, name, function(host)
        run_case(case, host, check, setup, limit)
    end)
end

register("text_printed_after_entry_matches_with_matched_at_entry_false", "late")
register("text_on_screen_matches_on_one_read_before_the_first_sleep", "entry", function(f)
    test.assertEquals(counter(f, "capture-pane", 1), 1)
end)
register("line_wider_than_the_pane_matches_across_the_wrap", "wrapped")
register("killed_pane_ends_the_wait_with_the_text_seen", "pane_killed")
register("exited_pane_with_remain_on_exit_ends_as_pane_exited", "remain_on_exit")
register("killed_server_ends_the_wait_from_the_stale_generation", "server_killed")

fixture.each_host(M, "killed_server_behind_a_stopped_client_ends_from_stderr", function(host)
    fixture.with(function(f)
        local program = start(f, host, "server_killed_stopped")
        local client = f:spawn(
            { "-C", "attach" },
            { stdin = "pipe", stdout = "null", stderr = "null" }
        )
        local ok, failure = pcall(function()
            test.assertTrue(
                program:expect(function(fresh)
                    return fresh:find("READY\n", 1, true) ~= nil
                end, 5),
                program:errors()
            )
            -- A control client has to be attached before it is stopped.
            child.pump(function()
                return f:try("list-clients").stdout:find("%S") ~= nil
            end, 5, 50)
            client:kill("sigstop")
            f:spawn({ "kill-server" }):finish(10)
            files.write(f.path .. "/killed", "")
            finish(program, "server_killed_stopped")
        end)
        client:kill("sigcont")
        client:close()
        if not ok then
            error(failure, 0)
        end
    end)
end)

register("cancel_during_the_pause_returns_before_the_interval", "cancel", nil, nil, 3)
register("cancel_during_an_in_flight_read_ends_the_request", "cancel_inflight", nil, nil, 4)
register("deadline_during_an_in_flight_read_carries_the_text", "deadline_inflight", nil, nil, 4)
register("history_beyond_the_read_limit_does_not_fail_the_wait", "history")
register("history_under_the_read_limit_is_the_control", "history_under")
register("reads_fire_only_the_capture_hook", "hooks", function(f)
    test.assertTrue(counter(f, "capture-pane", 2) >= 2)
    for _, name in ipairs({ "display-message", "list-panes", "show-options" }) do
        test.assertEquals(counter(f, name), 0, name)
    end
end)
register("match_wins_over_a_pane_the_hook_killed", "matcher_first", nil, function(f)
    local version = f:version()
    if not fixture.at_least(version, 3, 8) then
        test.skip(("the hook runs after the marker before tmux 3.8; daemon is %s"):format(version))
    end
end)
register("options_are_validated", "validation")
register("runtime_close_leaves_no_timer_or_pin_directory", "close", nil, nil, 3)
register("printing_hook_output_joins_the_text", "hook_output", nil, function(f)
    local version = f:version()
    if not fixture.at_least(version, 3, 5, "a") then
        test.skip(("tmux drops a hook's printed output before 3.5a; daemon is %s"):format(version))
    end
end)
register("typed_command_echo_matches_the_needle", "typed_echo")

return M
