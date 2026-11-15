-- The integration runner hands the sandbox canary's clients nothing that selects a server.
--
-- The canary runs through tests/run_integration.lua, and through a bare luaunit run that does not
-- make a sandbox, with a recording script named tmux first on PATH and as TMUX_BIN, and decoys in
-- the environment. The recorder cannot name a socket, so the canary fails; what matters is what it
-- was called with. Assertions compare names and words, never environment values.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local recorder = require("tests.support.recorder")
local repo = require("support.repo")
local sandbox = require("tests.support.sandbox")
local M = {}

local DECOYS = {
    TMUX = "/decoy/server,1,0",
    TMUX_PANE = "%9",
    LIBTMUX_SOCKET = "decoy-name",
    LIBTMUX_SOCKET_PATH = "/decoy/path",
    LIBTMUX_SOCKET_NAME = "decoy-other",
    TMUX_TMPDIR = "/decoy/tmpdir",
}

local root, log

function M.setUp()
    -- Short and under /tmp so the sandbox fits a socket path wherever TMPDIR points.
    root = fs.mkdtemp("t-")
    log = root .. "/calls"
end

function M.tearDown()
    fs.remove_tree(root)
end

--- The environment of a developer shell with decoys, the recorder as tmux, and a TMPDIR of its own.
local function environment()
    local env = fixture.environment()
    env.TMUX_TMPDIR, env[sandbox.MARKER] = nil, nil
    for name, value in pairs(DECOYS) do
        env[name] = value
    end
    env.PATH = root .. "/bin:" .. (os.getenv("PATH") or "")
    env.TMPDIR, env.TMUX_BIN = root, recorder.install(root .. "/bin")
    env.FAKE_TMUX_LOG, env.FAKE_TMUX_ROOT = log, root
    return env
end

local function assert_clients_saw_only_the_sandbox()
    local calls = recorder.calls(log)
    test.assertTrue(#calls >= 1, "the canary started no client")
    local markers = {}
    for _, call in ipairs(calls) do
        test.assertEquals(call.argv, { "-N", "-f", "/dev/null", "list-sessions" })
        test.assertEquals(call.set, {})
        test.assertEquals(call.tmpdir, "inside")
        markers[call.marker] = true
    end
    -- One case moves TMUX_TMPDIR to a directory of its own, which the marker does not name.
    test.assertTrue(markers.matches)
end

function M.test_the_runner_gives_the_canary_a_sandbox_and_no_selector()
    local result = child.run(
        { fixture.luajit(), "tests/run_integration.lua", "sandbox" },
        { env = environment(), cwd = repo.root, timeout = 30 }
    )
    -- The recorder names no socket, so the cases that read tmux's answer fail.
    test.assertEquals(result.code, 1, result.stderr)
    local output = result.stdout .. result.stderr
    test.assertNil(output:find("refusing to start a client", 1, true))
    test.assertNil(output:find("left sockets in the sandbox", 1, true))
    assert_clients_saw_only_the_sandbox()
end

function M.test_a_runner_that_cannot_make_a_sandbox_exits_before_any_client()
    local refuse = [[
        package.path = %q
        require("support.repo").use_rocks()
        local host = require("tests.support.sandbox_host")
        host.prepare = function()
            error("no temporary directory is short enough for a tmux socket path", 0)
        end
        dofile("tests/run_integration.lua")
    ]]
    local result = child.run(
        { fixture.luajit(), "-e", refuse:format(package.path) },
        { env = environment(), cwd = repo.root, timeout = 30 }
    )
    test.assertEquals(result.code, 2, result.stderr)
    test.assertStrContains(
        result.stderr,
        "libtmux-lua tests refused to run: no temporary directory is short enough"
    )
    test.assertNil((result.stdout .. result.stderr):find("decoy", 1, true))
    test.assertEquals(recorder.calls(log), {}, "a client started without a sandbox")
end

function M.test_a_run_that_bypasses_the_runner_stops_the_canary_before_it_starts_a_client()
    -- The control: run the suite with luaunit alone, so nothing makes the sandbox.
    local result = child.run({
        fixture.luajit(),
        "scripts/support/run_tests.lua",
        "tests/integration/test_sandbox.lua",
    }, { env = environment(), cwd = repo.root, timeout = 30 })
    test.assertNotEquals(result.code, 0)
    test.assertStrContains(
        result.stdout .. result.stderr,
        "refusing to start a client outside the sandbox"
    )
    test.assertEquals(recorder.calls(log), {}, "a client started outside the sandbox")
end

return M
