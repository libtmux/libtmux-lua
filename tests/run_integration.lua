-- Run the integration suites in a tmux sandbox, with fixture cleanup on SIGINT and SIGTERM.
--
--   luajit tests/run_integration.lua [SUITE...] [--filter TEXT]
--
-- A suite is tests/integration/test_<name>.lua; SUITE is <name>. Each suite returns a table of
-- luaunit tests that start real tmux servers, and run the paired tests/integration/<name>.lua
-- programs under luv and under Neovim. scripts/check/check.lua runs this as the `integration` gate.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../scripts/?.lua;" .. here .. "/../?.lua;" .. package.path
local repo = require("support.repo")
repo.use_rocks()
local argparse = require("argparse")
local child = require("tests.support.child")
local fs = require("support.fs")
local luaunit = require("luaunit")
local sandbox_host = require("tests.support.sandbox_host")

local cli = argparse("run_integration.lua", "Run the integration suites in a tmux sandbox.")
cli:argument("suites", "suite names, such as version_check"):args("*")
cli:option("--filter", "run only the tests whose name contains this text")
local parsed, arguments = cli:pparse({ ... })
if not parsed then
    io.stderr:write(cli:get_usage(), "\nrun_integration.lua: error: ", arguments, "\n")
    os.exit(2)
end

--- The suite files to run, as names without the test_ prefix.
local function discover(requested)
    if #requested > 0 then
        return requested
    end
    local names = {}
    for _, file in ipairs(fs.list(repo.root .. "/tests/integration")) do
        local name = file:match("^test_(.+)%.lua$")
        if name then
            names[#names + 1] = name
        end
    end
    return names
end

--- Once a signal cancelled the run, the tests that have not started are skipped.
local function guard(suite)
    for name, test in pairs(suite) do
        if type(test) == "function" and name:match("^test") then
            suite[name] = function(...)
                if child.cancelled then
                    luaunit.skip("the run was cancelled")
                end
                return test(...)
            end
        end
    end
    return suite
end

local function run()
    child.watch_signals()
    for _, name in ipairs(discover(arguments.suites)) do
        assert(name:match("^[a-z_]+$"), "invalid integration suite name")
        _G["Test_" .. name] = guard(require("tests.integration.test_" .. name))
    end
    local options = { "--output", "text", "--verbose" }
    if arguments.filter then
        options[#options + 1] = "--pattern"
        options[#options + 1] = arguments.filter
    end
    local failures = luaunit.LuaUnit.run(unpack(options))
    if child.cancelled then
        local name = child.cancelled == 2 and "SIGINT" or "SIGTERM"
        io.stderr:write("integration tests cancelled by ", name, "\n")
        return 128 + child.cancelled
    end
    return failures == 0 and 0 or 1
end

os.exit(sandbox_host.run(run))
