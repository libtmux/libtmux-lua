local test = require("luaunit")
local files = require("support.files")
local fs = require("support.fs")
local gates = require("check.gates")
local proc = require("support.proc")
local repo = require("support.repo")
local runtime = require("support.runtime")
local M = {}

local LUAJIT = runtime.executable_path(arg and arg[-1] or "luajit")
local CHECK = repo.root .. "/scripts/check/check.lua"

local DECOYS = {
    TMUX = "/decoy/server,1,0",
    TMUX_PANE = "%9",
    LIBTMUX_SOCKET = "decoy-name",
    LIBTMUX_SOCKET_PATH = "/decoy/path",
    LIBTMUX_SOCKET_NAME = "decoy-other",
    LUA_PATH = "/decoy/?.lua",
    LUA_CPATH_5_4 = "/decoy/?.so",
}

local function names(env)
    local found = {}
    for name in pairs(env) do
        found[#found + 1] = name
    end
    table.sort(found)
    return found
end

local function with(base, extra)
    local env = {}
    for name, value in pairs(base) do
        env[name] = value
    end
    for name, value in pairs(extra) do
        env[name] = value
    end
    return env
end

function M.test_child_environments_carry_nothing_that_selects_a_server_or_a_lua_path()
    local env = gates.clean_environment(
        with({ HOME = "/home/x", LIBTMUX_TEST_TMUX = "/custom/tmux", PATH = "/usr/bin" }, DECOYS)
    )
    test.assertEquals(names(env), { "HOME", "LIBTMUX_TEST_TMUX", "PATH" })
    local lua = gates.lua_environment(
        runtime.executable_path("lua"),
        with({ LIBTMUX_TEST_TMUX = "/custom/tmux", PATH = "/usr/bin" }, DECOYS)
    )
    for name in pairs(DECOYS) do
        test.assertNil(lua[name] and lua[name]:find("decoy", 1, true) and name)
    end
    test.assertEquals(lua.LIBTMUX_TEST_TMUX, "/custom/tmux")
    test.assertStrContains(lua.LUA_PATH, repo.root .. "/lua/?.lua")
    test.assertNotNil(lua.LIBTMUX_TEST_LUA)
end

function M.test_headings_become_the_anchors_github_makes()
    test.assertEquals(gates.slug("Start a `private` server"), "start-a-private-server")
    test.assertEquals(gates.slug("What it **leaves** out"), "what-it-leaves-out")
    test.assertEquals(gates.slug("Run: it (now)"), "run-it-now")
    test.assertEquals(gates.slug("<b>Bold</b> text"), "bold-text")
end

function M.test_the_docs_gate_names_a_broken_link_and_a_broken_anchor()
    local path = repo.root .. "/docs/zz-gate-fixture.md"
    local function attempt(text)
        files.write(path, text)
        local ok, failure = pcall(gates.docs)
        os.remove(path)
        return ok, tostring(failure)
    end
    local ok, failure = attempt("# Fixture\n\n[gone](missing-file.md)\n")
    test.assertFalse(ok)
    test.assertStrContains(failure, "Broken link in docs/zz-gate-fixture.md: missing-file.md")
    ok, failure = attempt("# Fixture\n\n[gone](#nowhere)\n")
    test.assertFalse(ok)
    test.assertStrContains(failure, "Broken anchor in docs/zz-gate-fixture.md: #nowhere")
    ok = attempt("# Fixture\n\n[here](#fixture) and [out](https://example.test/)\n")
    test.assertTrue(ok)
end

function M.test_the_mid_gate_keeps_the_script_suites_alive_to_the_mid_budget()
    local steps = gates.steps("mid", { lua = "lua", suites = {} })
    local longest = 0
    for _, step in ipairs(steps) do
        longest = math.max(longest, step.timeout or 0)
    end
    test.assertTrue(longest >= 30, "the script suites are killed before the mid budget")
    test.assertEquals(gates.budget("mid"), 30)
    test.assertEquals(gates.budget("unit"), 5)
    test.assertEquals(gates.budget("outer"), 300)
end

function M.test_the_mid_gate_runs_every_script_suite_including_this_one()
    local argv
    for _, step in ipairs(gates.steps("mid", { lua = "lua", suites = {} })) do
        if step.argv and step.argv[2] and step.argv[2]:find("run_tests.lua", 1, true) then
            argv = table.concat(step.argv, " ")
        end
    end
    test.assertNotNil(argv)
    test.assertStrContains(argv, "scripts/check/tests/test_check.lua")
    test.assertStrContains(argv, "scripts/ci_plan/tests/test_ci_plan.lua")
end

function M.test_the_integration_gates_run_the_lua_runner_and_pass_suite_names_on()
    local function runner(gate, suites)
        local argv = assert(gates.steps(gate, { lua = "lua", suites = suites })[1].argv)
        test.assertEquals(argv[1], LUAJIT)
        return { unpack(argv, 2) }
    end
    test.assertEquals(runner("integration", {}), { "tests/run_integration.lua" })
    test.assertEquals(
        runner("integration", { "buffer", "pane" }),
        { "tests/run_integration.lua", "buffer", "pane" }
    )
    test.assertEquals(runner("refusal", {}), { "tests/run_integration.lua", "version_check" })
end

function M.test_the_outer_gate_runs_every_integration_suite_not_the_unit_suite_names()
    local found
    for _, step in ipairs(gates.steps("outer", { lua = "lua", suites = {} })) do
        if step.argv and (step.argv[2] or ""):find("run_integration.lua", 1, true) then
            found = step.argv
        end
    end
    test.assertEquals({ unpack(assert(found), 2) }, { "tests/run_integration.lua" })
end

function M.test_suite_names_apply_only_to_the_unit_and_integration_gates()
    local result = proc.run({ LUAJIT, CHECK, "format", "query" }, { cwd = repo.root })
    test.assertEquals(result.code, 2)
    test.assertStrContains(
        result.stderr,
        "suite names apply only to the unit and integration gates"
    )
end

function M.test_check_enters_the_sandbox_before_it_looks_for_a_tool()
    local result = proc.run({ LUAJIT, CHECK, "unit", "--lua", "/nonexistent/lua" }, {
        cwd = repo.root,
        env = with(proc.environment(), DECOYS),
    })
    test.assertEquals(result.code, 1)
    test.assertStrContains(result.stderr, "Missing /nonexistent/lua")
    test.assertNil(result.stderr:find("decoy", 1, true))
    test.assertNil(result.stderr:find("refused to run", 1, true))
end

function M.test_a_gate_that_fails_reports_the_exit_code_of_its_command()
    local directory = fs.mkdtemp("libtmux-lua-check-")
    local result = proc.run({ LUAJIT, CHECK, "docs" }, {
        cwd = repo.root,
        env = with(proc.environment(), { PATH = directory .. ":" .. (os.getenv("PATH") or "") }),
    })
    fs.remove_tree(directory)
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout, '"gate":"docs"')
end

return M
