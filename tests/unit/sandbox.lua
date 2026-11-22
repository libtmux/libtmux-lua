local t = require("luaunit")
local sandbox = require("tests.support.sandbox")
local M = {}

local DIRECTORY = "/tmp/" .. sandbox.PREFIX .. "test0001"
local DECOYS = {
    TMUX = "/decoy/server,1,0",
    TMUX_PANE = "%9",
    LIBTMUX_SOCKET = "decoy-name",
    LIBTMUX_SOCKET_PATH = "/decoy/path",
    LIBTMUX_SOCKET_NAME = "decoy-other",
}

local function lookup(values)
    return function(name)
        return values[name]
    end
end

local function inside(extra)
    local values = { TMUX_TMPDIR = DIRECTORY, [sandbox.MARKER] = DIRECTORY }
    for name, value in pairs(extra or {}) do
        values[name] = value
    end
    return values
end

function M.test_this_process_runs_inside_the_sandbox()
    t.assertEquals(sandbox.violations(os.getenv), {})
end

function M.test_a_sandboxed_environment_has_no_findings()
    t.assertEquals(sandbox.violations(lookup(inside())), {})
    t.assertEquals(
        sandbox.violations(lookup(inside({
            LIBTMUX_TEST_LUA = "lua",
            LIBTMUX_TEST_TMUX = "/opt/tmux/bin/tmux",
            TMUX_BIN = "tmux",
        }))),
        {}
    )
    t.assertFalse(sandbox.ambient("LIBTMUX_TEST_TMUX"))
    t.assertFalse(sandbox.ambient("TMUX_BIN"))
    for name in pairs(DECOYS) do
        t.assertTrue(sandbox.ambient(name), name)
    end
end

function M.test_tmux_binary_prefers_libtmux_test_tmux_and_ignores_blank_values()
    t.assertEquals(
        sandbox.tmux_binary(lookup({
            LIBTMUX_TEST_TMUX = "/custom/tmux",
            TMUX_BIN = "/legacy/tmux",
        })),
        "/custom/tmux"
    )
    for _, blank in ipairs({ "", " ", " \t\n" }) do
        t.assertEquals(
            sandbox.tmux_binary(lookup({
                LIBTMUX_TEST_TMUX = blank,
                TMUX_BIN = "/legacy/tmux",
            })),
            "/legacy/tmux"
        )
        t.assertEquals(
            sandbox.tmux_binary(lookup({
                LIBTMUX_TEST_TMUX = blank,
                TMUX_BIN = blank,
            })),
            "tmux"
        )
    end
    t.assertEquals(sandbox.tmux_binary(lookup({})), "tmux")
    t.assertEquals(
        sandbox.tmux_binary(lookup({ LIBTMUX_TEST_TMUX = "  " }), "/usr/bin/tmux"),
        "/usr/bin/tmux"
    )
end

function M.test_every_selector_is_named_without_its_value()
    local found = sandbox.violations(lookup(inside(DECOYS)))
    t.assertEquals(found, {
        "LIBTMUX_SOCKET is set",
        "LIBTMUX_SOCKET_NAME is set",
        "LIBTMUX_SOCKET_PATH is set",
        "TMUX is set",
        "TMUX_PANE is set",
    })
    t.assertNil(table.concat(found, " "):find("decoy", 1, true))
    t.assertEquals(sandbox.violations(lookup(inside({ TMUX = "" }))), { "TMUX is set" })
end

function M.test_tmux_tmpdir_must_be_the_sandbox_of_this_run()
    local long = DIRECTORY .. "/" .. ("x"):rep(sandbox.MAX_BYTES)
    local other = "TMUX_TMPDIR is not the sandbox directory of this run"
    local cases = {
        { "TMUX_TMPDIR is unset", { [sandbox.MARKER] = DIRECTORY } },
        { "TMUX_TMPDIR is unset", inside({ TMUX_TMPDIR = "" }) },
        { "TMUX_TMPDIR is not an absolute path", inside({ TMUX_TMPDIR = "relative/dir" }) },
        {
            "TMUX_TMPDIR is longer than " .. sandbox.MAX_BYTES .. " bytes",
            inside({ TMUX_TMPDIR = long, [sandbox.MARKER] = long }),
        },
        { other, inside({ TMUX_TMPDIR = "/tmp" }) },
        { other, inside({ [sandbox.MARKER] = "/tmp/other" }) },
        { other, { TMUX_TMPDIR = DIRECTORY } },
    }
    for _, case in ipairs(cases) do
        t.assertEquals(sandbox.violations(lookup(case[2])), { case[1] })
    end
end

return M
