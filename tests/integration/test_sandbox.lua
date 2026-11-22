-- A tmux client that names no socket looks only inside the sandbox.
--
-- Each case first requires the sandbox to hold, so a broken one fails before any client runs. The
-- clients here name no socket; the sandbox decides where they look, and no server listens there.
-- Failure messages are fixed text: the paths involved come from environment values.
--
-- The library has no default-server resolver: a connection that names no socket passes tmux none,
-- and tmux chooses. test_socket_default compares the socket tmux chose with
-- sandbox_host.default_socket, which these cases pin against tmux itself.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local sandbox = require("tests.support.sandbox")
local sandbox_host = require("tests.support.sandbox_host")
local uv = require("support.uv")
local M = {}

local binary

function M.setUp()
    test.assertEquals(
        sandbox.violations(os.getenv),
        {},
        "refusing to start a client outside the sandbox"
    )
    sandbox_host.check()
    binary = sandbox.tmux_binary(os.getenv)
end

--- A client that names no socket and may not start a server.
local function bare_client(env)
    local result = child.run({ binary, "-N", "-f", "/dev/null", "list-sessions" }, {
        env = env,
        timeout = 5,
    })
    return result.code, result.stdout .. result.stderr
end

function M.test_a_client_that_names_no_socket_looks_only_in_the_sandbox()
    local env = fixture.environment()
    local status, output = bare_client(env)
    test.assertNotEquals(status, 0, "a bare client found a server")
    test.assertNotNil(
        output:find(sandbox_host.default_socket(env), 1, true),
        "the bare client did not look in the sandbox's default socket"
    )
end

function M.test_the_default_socket_moves_with_tmux_tmpdir_in_tmux_itself()
    local elsewhere = fs.mkdtemp("elsewhere-", os.getenv("TMUX_TMPDIR"))
    local ok, failure = pcall(function()
        local env = fixture.environment({ TMUX_TMPDIR = elsewhere })
        local status, output = bare_client(env)
        test.assertNotEquals(status, 0, "a bare client found a server")
        local moved = sandbox_host.default_socket(env)
        local home = sandbox_host.default_socket(fixture.environment())
        test.assertNotNil(output:find(moved, 1, true), "tmux did not follow TMUX_TMPDIR")
        test.assertNotEquals(moved, home, "the control cannot tell two directories apart")
        test.assertNil(
            output:find(home, 1, true),
            "tmux named the sandbox's default socket for another TMUX_TMPDIR"
        )
    end)
    fs.remove_tree(elsewhere)
    if not ok then
        error(failure, 0)
    end
end

function M.test_removing_tmux_tmpdir_would_name_the_real_default_socket()
    -- Computed only: a client run without TMUX_TMPDIR could reach the real server.
    local env = fixture.environment()
    env.TMUX_TMPDIR = nil
    local real = sandbox_host.default_socket(env)
    test.assertEquals(
        real,
        ("%s/tmux-%d/default"):format(uv.fs_realpath("/tmp"), uv.os_get_passwd().uid)
    )
    test.assertNotEquals(
        real,
        sandbox_host.default_socket(fixture.environment()),
        "removing TMUX_TMPDIR changed nothing"
    )
    test.assertNotEquals(
        real:sub(1, #os.getenv("TMUX_TMPDIR")),
        os.getenv("TMUX_TMPDIR"),
        "the real default lies inside the sandbox"
    )
end

return M
