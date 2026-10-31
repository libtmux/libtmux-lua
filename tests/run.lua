local sandbox = require("tests.support.sandbox")

local refusals = sandbox.violations(os.getenv)
if #refusals > 0 then
    io.stderr:write(
        "libtmux-lua tests refused to run: ",
        table.concat(refusals, "; "),
        "\nRun them through scripts/check.py, which makes the sandbox.\n"
    )
    os.exit(2)
end

local luaunit = require("luaunit")

local suites = { "imports", "query", "runtime" }
if #arg > 0 then
    suites = arg
end
for _, name in ipairs(suites) do
    assert(name:match("^[a-z_]+$"), "invalid test suite name")
    _G["Test_" .. name] = require("tests.unit." .. name)
end

os.exit(luaunit.LuaUnit.run("--verbose"))
