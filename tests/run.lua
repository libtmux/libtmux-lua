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
