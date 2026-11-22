-- A server the library starts is private, answers, and is gone after stop.
--
-- The Lua program reports its directory and socket; this side checks them with its own
-- connection, so a library that believed it had stopped cannot vouch for itself.
local test = require("luaunit")
local child = require("tests.support.child")
local files = require("support.files")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local repo = require("support.repo")
local sandbox_host = require("tests.support.sandbox_host")
local uv = require("support.uv")
local M = {}

local DECOYS = {
    TMUX = "/decoy/server,1,0",
    TMUX_PANE = "%9",
    LIBTMUX_SOCKET = "decoy-name",
    LIBTMUX_SOCKET_PATH = "/decoy/path",
    LIBTMUX_SOCKET_NAME = "decoy-other",
}

-- Passes every command through except kill-server, while the flag file exists.
local function stuck_tmux(path, real, flag)
    files.write(
        path,
        table.concat({
            "#!" .. fixture.which(arg and arg[-1] or "luajit"),
            "package.path, package.cpath = " .. ("%q, %q"):format(package.path, package.cpath),
            'local uv = require("luv")',
            "for _, word in ipairs(arg) do",
            '    if word == "kill-server" and io.open('
                .. ("%q"):format(flag)
                .. ") then os.exit(0) end",
            "end",
            "local status",
            "local handle = uv.spawn("
                .. ("%q"):format(real)
                .. ", { args = arg, stdio = { 0, 1, 2 } }, function(code)",
            "    status = code",
            "end)",
            "while status == nil do uv.run('once') end",
            "handle:close()",
            "os.exit(status)",
            "",
        }, "\n")
    )
    assert(uv.fs_chmod(path, 448))
end

local root, binary

function M.setUp()
    -- Short and under /tmp: the directory and its socket alias must fit sun_path.
    root = fs.mkdtemp("t-")
    binary = fixture.tmux()
end

function M.tearDown()
    fs.remove_tree(root)
end

--- Runs tests/integration/owned_server.lua for a case and returns its result and the lines it
--- reported.
local function launch(case, host, extra)
    local env = fixture.environment(extra)
    env.LIBTMUX_TEST_TMUX, env.TMUX_BIN = binary, binary
    env.OWNED_ROOT, env.LIBTMUX_OWNED_CASE = root, case
    env.LIBTMUX_TEST_LUA = env.LIBTMUX_TEST_LUA or fixture.lua()
    local argv = fixture.program_command(host or "luv", "owned_server", env)
    local result = child.run(argv, { env = env, cwd = repo.root, timeout = 20 })
    local reported = {}
    for line in result.stdout:gmatch("[^\n]+") do
        local key, value = line:match("^(%u+) (.*)$")
        if key == "DIR" or key == "SOCKET" or key == "RUN" then
            reported[key] = value
        end
    end
    return result, reported
end

local function assert_stopped(reported)
    test.assertNil(fs.stat(reported.DIR), "the directory survived")
    test.assertFalse(sandbox_host.answering(reported.SOCKET), "a server answers on the socket")
    test.assertEquals(fs.list(root), {}, "something was left under the root")
end

local function passes(case, host, extra)
    local result, reported = launch(case, host, extra)
    test.assertEquals(result.code, 0, result.stdout .. result.stderr)
    test.assertStrContains(result.stdout, "PASS")
    return reported
end

fixture.each_host(M, "a_started_server_answers_and_is_gone_after_stop", function(host)
    assert_stopped(passes("round_trip", host))
end)

function M.test_the_private_directory_belongs_to_the_caller_alone()
    local result, reported = launch("round_trip")
    test.assertEquals(result.code, 0, result.stdout .. result.stderr)
    test.assertEquals(reported.DIR:match("^(.*)/[^/]+$"), root)
    test.assertStrMatches(reported.DIR:match("[^/]+$"), "libtmux%-.*")
    test.assertEquals(reported.SOCKET:match("[^/]+$"), "tmux.sock")
end

function M.test_the_daemon_stays_up_with_no_session()
    assert_stopped(passes("zero_sessions"))
end

function M.test_the_daemon_inherits_no_selector_and_a_private_tmpdir()
    local extra = { TMUX_TMPDIR = "/decoy/tmpdir" }
    for name, value in pairs(DECOYS) do
        extra[name] = value
    end
    -- The decoys are for the library to refuse to pass on to the daemon it starts.
    assert_stopped(passes("environment", "luv", extra))
end

function M.test_leaving_the_scope_stops_the_server_however_the_body_ends()
    assert_stopped(passes("scope"))
    test.assertEquals(fs.list(root), {})
end

function M.test_leaving_the_runtime_stops_a_server_nobody_stopped()
    for _, failing in ipairs({ false, "error" }) do
        local expected = failing and "RUN ERROR " or "RUN OK "
        local result, reported = launch("exit", "luv", failing and { OWNED_EXIT = failing } or nil)
        test.assertEquals(result.code, 0, result.stdout .. result.stderr)
        local last = result.stdout:gsub("\n$", ""):match("[^\n]*$")
        test.assertEquals(last:sub(1, #expected), expected, result.stdout)
        assert_stopped(reported)
    end
end

function M.test_a_daemon_that_survives_kill_server_keeps_the_directory_and_stop_can_retry()
    local wrapper, flag = root .. ".tmux", root .. ".flag"
    stuck_tmux(wrapper, binary, flag)
    files.write(flag, "")
    local result, reported = launch(
        "stuck",
        "luv",
        { OWNED_STUCK_BIN = wrapper, OWNED_STUCK_FLAG = flag, OWNED_REAL_TMUX = binary }
    )
    if sandbox_host.answering(reported.SOCKET or "/nonexistent") then
        child.run({ binary, "-N", "-S", reported.SOCKET, "kill-server" }, { timeout = 5 })
    end
    os.remove(wrapper)
    os.remove(flag)
    test.assertEquals(result.code, 0, result.stdout .. result.stderr)
    assert_stopped(reported)
end

function M.test_a_server_the_program_left_under_the_directory_is_stopped_and_reported()
    assert_stopped(passes("leak"))
end

function M.test_a_root_too_long_for_a_socket_path_creates_nothing()
    passes("overflow")
    test.assertEquals(fs.list(root), {})
end

return M
