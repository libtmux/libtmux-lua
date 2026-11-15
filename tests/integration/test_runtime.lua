-- Real host-loop ownership and callback scheduling regressions.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local repo = require("support.repo")
local uv = require("support.uv")
local M = {}

local function run(argv, env)
    return child.run(
        argv,
        { env = env or fixture.environment(), cwd = repo.root, timeout = fixture.DEADLINE }
    )
end

--- The environment for Neovim, which runs the program in its own Lua.
local function nvim_environment(extra)
    local env = fixture.environment(extra)
    env.LUA_CPATH = nil
    return env
end

local function nvim(...)
    local argv = { fixture.nvim(), "--headless", "-u", "NONE", "-i", "NONE" }
    for _, word in ipairs({ ... }) do
        argv[#argv + 1] = word
    end
    return argv
end

function M.test_foreign_luv_callback_cannot_drive_nested_loop()
    local result = run({ fixture.lua(), "tests/support/luv_reentry.lua" })
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout, "Foreign luv callback rejection PASS")
end

function M.test_nvim_borrows_loop_and_preserves_unrelated_handle()
    local result =
        run(nvim("-c", "lua dofile('tests/support/nvim_runtime.lua')"), nvim_environment())
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout .. result.stderr, "Neovim runtime smoke PASS")
end

function M.test_neovim_example_starts_its_own_server_and_reports_the_pane_count()
    -- Short and under /tmp: the example's private directory must fit a socket path.
    local root = fs.mkdtemp("t-")
    local bin = fs.mkdtemp("libtmux-lua-")
    local ok, failure = pcall(function()
        -- The example finds tmux with exepath, so name the selected build "tmux" on PATH.
        assert(uv.fs_symlink(fixture.tmux(), bin .. "/tmux"))
        local env =
            nvim_environment({ TMPDIR = root, PATH = bin .. ":" .. (os.getenv("PATH") or "") })
        local result = run(
            nvim("--cmd", "set runtimepath+=.", "-c", "luafile tests/support/nvim_example.lua"),
            env
        )
        test.assertEquals(result.code, 0, result.stdout .. result.stderr)
        test.assertEquals(result.stdout, "Panes: 1\n")
        test.assertEquals(fs.list(root), {}, "the example left its server directory")
    end)
    fs.remove_tree(bin)
    fs.remove_tree(root)
    if not ok then
        error(failure, 0)
    end
end

return M
