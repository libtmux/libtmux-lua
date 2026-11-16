-- The reserved native bootstrap reads the daemon release without user effects.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local M = {}

local DEADLINE = 3
local FLOOR = "3.3a"
-- Each hook with the command that fires it. tmux has after-hooks only for commands that opt in;
-- if-shell and run-shell carry existing command fences and have none through next-3.9,
-- so those two arm only on a tmux that adds them. Discovery reserves list-commands.
local HOOKS = {
    { "after-display-message", "@after-display", { "display-message", "-p", "control" } },
    { "after-show-options", "@after-show-options", { "show-options", "-s" } },
    { "command-error", "@command-error", { "has-session", "-t", "=missing-control" } },
    { "after-if-shell", "@after-if-shell", { "if-shell", "-F", "1", "" } },
    { "after-run-shell", "@after-run-shell", { "run-shell", "true" } },
}
local ranked = {}

--- Whether a report ranks at or above each release, as the library decides: true, false, or "none"
--- when the report names no release. The grammar lives in fields.lua only; this asks it instead of
--- keeping a second copy.
local function ranks(version, ...)
    local required = table.concat({ ... }, ",")
    local key = version .. "|" .. required
    if not ranked[key] then
        local env = fixture.environment({
            LIBTMUX_VERSION_CHECK_CASE = "ranks",
            LIBTMUX_RANK_VERSION = version,
            LIBTMUX_RANK_REQUIRED = required,
        })
        local words = {}
        local out = fixture.program("luv", "version_check", env, { timeout = DEADLINE }).stdout
        for word in out:gmatch("[^,\n]+") do
            words[#words + 1] = word == "true" or (word ~= "false" and "none")
        end
        ranked[key] = words
    end
    return ranked[key]
end

local function supported(version)
    return ranks(version, FLOOR)[1] == true
end

--- The part of the refusal that tells an old daemon from a rejected release.
local function refusal_wording(version)
    local at_32 = ranks(version, "3.2")[1]
    if at_32 == "none" then
        return "no release"
    end
    if at_32 then
        return "older than 3.3a"
    end
    if os.getenv("TMUX_CLIENT_BIN") and ranks(version, "3.1")[1] == true then
        return "older than 3.3a"
    end
    -- Before 3.2 the client rejects -N; incompatible protocol peers refuse earlier.
    return ("tmux %s is older than 3.2"):format(
        os.getenv("TMUX_CLIENT_BIN") and "server" or "client"
    )
end

local function arm_hooks(f)
    local armed = {}
    for _, hook in ipairs(HOOKS) do
        local name, option = hook[1], hook[2]
        -- command-error exists from tmux 3.5; older daemons refuse the hook.
        local result = f:try("set-hook", "-g", name, ("set-option -g %s fired"):format(option))
        armed[option] = result.code == 0
        if not armed[option] and name:match("^after%-") then
            test.assertStrContains(result.stderr, "invalid option", false, name)
        end
    end
    test.assertTrue(armed["@after-display"])
    return armed
end

--- What a refused connect must leave alone.
local function state(f)
    return {
        f:out("list-sessions", "-F", "#{session_name}"),
        f:out("list-windows", "-a", "-F", "#{window_id}"),
        f:out("list-panes", "-a", "-F", "#{pane_id}"),
        f:out("list-buffers", "-F", "#{buffer_name}:#{buffer_size}"),
        f:out("show-options", "-g", "@sentinel"),
        f:out("show-options", "-s"),
    }
end

local function fired(f, option)
    return f:out("list-commands", "-F", "#{" .. option .. "}", "list-sessions"):gsub("%s+$", "")
        == "fired"
end

--- Proves each armed hook fires for an ordinary command, then clears it.
local function exercise(f, armed)
    for _, hook in ipairs(HOOKS) do
        local option = hook[2]
        if armed[option] then
            f:try(unpack(hook[3]))
            test.assertTrue(fired(f, option), option)
            f:run("set-option", "-gu", option)
        end
    end
end

local function run_lua(f, mode, host, version, extra)
    local env = {
        LIBTMUX_EXPECT_REFUSAL = refusal_wording(version),
        TMUX_DAEMON_VERSION = version,
    }
    -- A newer client in front of an older daemon: the lane builds both.
    for _, name in ipairs({ "TMUX_CLIENT_BIN", "LIBTMUX_REFUSAL_MAX_MS" }) do
        env[name] = os.getenv(name)
    end
    env.LIBTMUX_VERSION_CHECK_CASE = mode
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    local result = f:program(host, "version_check", env, { timeout = DEADLINE })
    test.assertStrContains(result.stdout, mode .. " passed")
end

local function sorted_words(text)
    local words = {}
    for word in text:gmatch("%S+") do
        words[#words + 1] = word
    end
    table.sort(words)
    return words
end

fixture.each_host(M, "version_check_fires_no_hooks_and_refusal_has_no_effects", function(host)
    fixture.with(function(f)
        local version = f:version()
        local mode = supported(version) and "supported" or "refuse"
        if os.getenv("LIBTMUX_REQUIRE_REFUSED") then
            -- A refusal lane built from a supported release would prove nothing.
            test.assertEquals(mode, "refuse", version)
        end
        f:run("set-option", "-g", "@sentinel", "kept")
        f:run("set-buffer", "-b", "sentinel", "kept")
        local before = state(f)
        local armed = arm_hooks(f)
        exercise(f, armed)
        run_lua(f, mode, host, version)
        if mode == "supported" and ranks(version, "3.7")[1] == true then
            -- The control attachment verifies its daemon with the same probe.
            run_lua(f, "observe", host, version)
        end
        for _, hook in ipairs(HOOKS) do
            test.assertFalse(fired(f, hook[2]), hook[2])
        end
        local sessions = sorted_words(f:out("list-sessions", "-F", "#{session_name}"))
        test.assertEquals(
            sessions,
            mode == "supported" and { "fixture", "supported" } or { "fixture" }
        )
        test.assertEquals(f:pins(), {})
        if mode == "refuse" then
            -- A refused connect leaves sessions, options and buffers untouched.
            test.assertEquals(state(f), before)
        end
    end)
end)

-- No second copy of the grammar: bare -rc is accepted, -master and -dev are not.
function M.test_oracle_asks_the_library_grammar()
    test.assertTrue(supported("3.8-rc"))
    test.assertTrue(supported("next-3.9"))
    test.assertFalse(supported("3.3"))
    test.assertEquals(ranks("3.4-master", FLOOR)[1], "none")
    test.assertEquals(ranks("3.4-dev", FLOOR)[1], "none")
    test.assertEquals(refusal_wording("3.4-dev"), "no release")
    test.assertStrContains(
        refusal_wording("3.1c"),
        os.getenv("TMUX_CLIENT_BIN") and "older than 3.3a" or "is older than 3.2"
    )
    test.assertEquals(refusal_wording("3.3"), "older than 3.3a")
end

fixture.each_host(M, "control_fence_refuses_another_daemon_and_attaches_nothing", function(host)
    fixture.with(function(f)
        local version = f:version()
        if not supported(version) then
            test.skip("refused release")
        end
        if ranks(version, "3.7")[1] ~= true then
            test.skip("control observation needs tmux 3.7")
        end
        -- A quiet daemon: tmux before 3.7 can crash on a notification during identify.
        local session = f:out("display-message", "-p", "#{session_id}"):gsub("%s+$", "")
        f:run("set-option", "-g", "@sentinel", "kept")
        f:run("set-buffer", "-b", "sentinel", "kept")
        local before = state(f)
        for _, lie in ipairs({ "wrong_pid", "wrong_version", "right" }) do
            run_lua(f, "control_fence_" .. lie, host, version, { TMUX_TEST_SESSION = session })
            test.assertEquals(f:out("list-clients"), "", lie)
            test.assertEquals(state(f), before, lie)
        end
    end)
end)

function M.test_snapshot_decodes_names_with_braces()
    fixture.with(function(f)
        local version = f:version()
        if not supported(version) then
            test.skip("refused release")
        end
        f:run("new-session", "-d", "-s", "br{ace}s", "exec /bin/cat")
        local result = f:program("luv", "version_check", {
            LIBTMUX_VERSION_CHECK_CASE = "snapshot",
            LIBTMUX_EXPECT_NAME = "br{ace}s",
        }, { timeout = DEADLINE })
        test.assertStrContains(result.stdout, "snapshot passed")
    end)
end

--- The NUL-separated words before the first NUL-newline.
local function argv_of(output)
    local stop = assert(output:find("\0\n", 1, true), "the program printed no argv")
    local words, position = {}, 1
    while position <= stop do
        local nul = output:find("\0", position, true)
        words[#words + 1] = output:sub(position, nul - 1)
        position = nul + 1
    end
    return words
end

function M.test_fence_refuses_another_daemon_before_any_effect()
    fixture.with(function(f)
        local version = f:version()
        if ranks(version, "3.2")[1] ~= true then
            test.skip("the client has no -N before tmux 3.2")
        end
        local marker = "unknown command: libtmux-version-0123456789abcdef-"
        local pid = f:out("display-message", "-p", "#{pid}"):gsub("%s+$", "")
        local started = f:out("display-message", "-p", "#{start_time}"):gsub("%s+$", "")
        local modes = {
            { "fence_wrong_version", true },
            { "fence_wrong_pid", true },
            { "fence_wrong_start", true },
            { "fence_right", false },
        }
        for _, case in ipairs(modes) do
            local mode, refused = case[1], case[2]
            local built = f:program("luv", "version_check", {
                TMUX_DAEMON_VERSION = version,
                TMUX_DAEMON_PID = pid,
                TMUX_DAEMON_START = started,
                LIBTMUX_VERSION_CHECK_CASE = mode,
            }, { timeout = DEADLINE })
            local result = child.run(argv_of(built.stdout), { env = f.env, timeout = DEADLINE })
            local sessions = sorted_words(f:out("list-sessions", "-F", "#{session_name}"))
            if refused then
                test.assertEquals(result.code, 1, mode)
                test.assertEquals(result.stderr, marker .. "\n", mode)
                test.assertEquals(sessions, { "fixture" }, mode)
            else
                test.assertEquals(result.code, 0, result.stderr)
                test.assertEquals(sessions, { "fenced", "fixture" })
            end
        end
    end)
end

return M
