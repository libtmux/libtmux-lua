-- A connection that names no socket reaches the server tmux picks, or the one a variable names.
--
-- Three servers run: one on an explicit socket (session "fixture"), one on the sandbox's default
-- socket (session "bare") and one on a named socket in the sandbox (session "named"). Each case
-- connects with only the options and environment it names and reads back the sessions of the
-- server that answered. No case can reach a server outside the sandbox: its TMUX_TMPDIR is the
-- sandbox's, and TMUX names the fixture's socket where a case sets it.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local sandbox_host = require("tests.support.sandbox_host")
local uv = require("support.uv")
local M = {}

local f, binary, name, default, named
---@type fun()[]
local cleanups

local function cleanup(action)
    cleanups[#cleanups + 1] = action
end

--- Stops the server, waits until it has gone and removes the socket tmux leaves behind: the
--- sandbox fails a run that leaves any socket in it, a dead one included.
local function stop(socket, pid)
    child.run({ binary, "-N", "-S", socket, "kill-server" }, { env = f.env })
    test.assertEquals(child.wait_gone({ pid }, 3), {}, "a server did not stop")
    os.remove(socket)
end

--- Starts a server with one session, through a client that names its socket as given.
---@return integer pid
local function start(session, socket, selector)
    local argv = { binary }
    for _, word in ipairs(selector) do
        argv[#argv + 1] = word
    end
    for _, word in ipairs({
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        session,
        "-P",
        "-F",
        "#{pid}",
        "exec /bin/cat",
    }) do
        argv[#argv + 1] = word
    end
    local started = child.run(argv, { env = f.env })
    test.assertEquals(started.code, 0, started.stderr)
    local pid = assert(tonumber(started.stdout), started.stdout)
    cleanup(function()
        stop(socket, pid)
    end)
    return pid
end

local function setup()
    cleanups = {}
    f = fixture.new()
    f:open()
    cleanup(function()
        f:close()
    end)
    local ok, failure = pcall(function()
        binary = f.binary
        name = "libtmux-lua-default-" .. uv.os_getpid()
        local base = ("%s/tmux-%d"):format(
            uv.fs_realpath(os.getenv("TMUX_TMPDIR")),
            uv.os_get_passwd().uid
        )
        default = sandbox_host.default_socket(fixture.environment())
        named = base .. "/" .. name
        start("bare", default, {})
        start("named", named, { "-L", name })
    end)
    if not ok then
        error(failure, 0)
    end
end

local function teardown()
    local first
    for index = #cleanups, 1, -1 do
        local ok, failure = pcall(cleanups[index])
        first = first or (not ok and failure) or nil
    end
    cleanups = {}
    if first then
        error(first, 0)
    end
end

-- Each test starts its servers in setup and stops them in teardown. Like fixture.with, it raises a
-- server left running even when the test skipped.
local function scenario(case)
    return function()
        local ok, result = pcall(function()
            setup()
            return case()
        end)
        local closed, failure = pcall(teardown)
        return fixture.settle(ok, result, closed, failure)
    end
end

--- What the connection reached, as the Lua program reports it.
local function connect(host, explicit, observe, variables)
    local env = f:program_env(variables)
    env.TMUX_SOCKET = nil
    env.LIBTMUX_TEST_EXPLICIT_SOCKET = explicit
    env.LIBTMUX_TEST_OBSERVE = observe and "1" or nil
    local reached = {}
    for key, value in
        fixture
            .program(host, "socket_default", env, { timeout = 5 }).stdout
            :gmatch("([^\n:]+): ([^\n]*)")
    do
        reached[key] = value
    end
    return reached
end

--- The connection reached the server with this session, on this socket.
local function reaches(session, socket, variables, explicit)
    for _, host in ipairs(fixture.HOSTS) do
        local reached = connect(host, explicit, false, variables)
        local label = ("host %s"):format(host)
        test.assertEquals(reached.sessions, session, label)
        test.assertEquals(uv.fs_realpath(reached.socket), uv.fs_realpath(socket), label)
    end
end

function M.test_a_connection_that_names_no_socket_reaches_the_default_server()
    reaches("bare", default, {})
end

function M.test_socket_path_variable_names_the_server()
    reaches("fixture", f.socket, { LIBTMUX_SOCKET_PATH = f.socket })
end

function M.test_socket_variable_names_the_server_by_socket_name()
    reaches("named", named, { LIBTMUX_SOCKET = name })
end

function M.test_the_path_wins_when_both_variables_are_set()
    reaches("fixture", f.socket, { LIBTMUX_SOCKET_PATH = f.socket, LIBTMUX_SOCKET = name })
end

function M.test_an_explicit_socket_comes_before_both_variables()
    reaches("fixture", f.socket, { LIBTMUX_SOCKET_PATH = default, LIBTMUX_SOCKET = name }, f.socket)
end

function M.test_inside_tmux_the_server_in_tmux_is_the_one_tmux_picks()
    local pane = ("%s,%d,0"):format(f.socket, f.server_pid)
    reaches("fixture", f.socket, { TMUX = pane })
    -- A name given to tmux is a socket choice, which TMUX no longer overrides.
    reaches("named", named, { TMUX = pane, LIBTMUX_SOCKET = name })
end

function M.test_a_control_client_attaches_to_the_server_the_connection_reached()
    fixture.require_control(f)
    for _, host in ipairs(fixture.HOSTS) do
        test.assertEquals(connect(host, nil, true, {})["control clients"], "1", host)
    end
end

function M.test_a_socket_path_variable_left_by_a_stopped_server_is_uncertain_not_absent()
    local stale = ("%s/stale-%d.sock"):format(os.getenv("TMUX_TMPDIR"), uv.os_getpid())
    local pid = start("stale", stale, { "-S", stale })
    child.run({ binary, "-N", "-S", stale, "kill-server" }, { env = f.env })
    test.assertEquals(child.wait_gone({ pid }, 3), {}, "the server did not stop")
    if not fs.stat(stale) then
        require("luaunit").skip("this tmux removes its socket when the server exits")
    end
    for _, host in ipairs(fixture.HOSTS) do
        test.assertEquals(
            connect(host, nil, false, { LIBTMUX_SOCKET_PATH = stale }),
            { error = "uncertain_generation" },
            host
        )
    end
    local missing = ("%s/missing-%d.sock"):format(os.getenv("TMUX_TMPDIR"), uv.os_getpid())
    test.assertEquals(
        connect("luv", nil, false, { LIBTMUX_SOCKET_PATH = missing }),
        { error = "invalid_endpoint" }
    )
end

function M.test_with_no_server_the_connection_fails_and_starts_none()
    local empty = fs.mkdtemp("empty-", os.getenv("TMUX_TMPDIR"))
    cleanup(function()
        fs.remove_tree(empty)
    end)
    for _, host in ipairs(fixture.HOSTS) do
        test.assertEquals(
            connect(host, nil, false, { TMUX_TMPDIR = empty }),
            { error = "invalid_endpoint" },
            host
        )
        test.assertEquals(sandbox_host.leaks(empty), {}, "a connection started a server")
    end
end

for key, case in pairs(M) do
    if key:match("^test_") then
        M[key] = scenario(case)
    end
end

return M
