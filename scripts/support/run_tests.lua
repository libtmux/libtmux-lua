-- Run luaunit suites without a tmux sandbox:
--
--   luajit scripts/support/run_tests.lua scripts/*/tests/test_*.lua [luaunit options]
--
-- A suite is a file that returns a table of test functions, like tests/unit/*.lua. Arguments that
-- end in .lua are suites; the rest go to luaunit, for example `--pattern mutation`.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../../?.lua;" .. package.path
require("support.repo").use_rocks()
local luaunit = require("luaunit")

local options = {}
for _, value in ipairs({ ... }) do
    local name = value:match("([^/]+)%.lua$")
    if name then
        _G["Test_" .. name:gsub("^test_", "")] = assert(loadfile(value))()
    else
        options[#options + 1] = value
    end
end
-- An empty list would make luaunit read the global `arg`, which holds the suite paths.
if #options == 0 then
    options = { "--output", "text" }
end
os.exit(luaunit.LuaUnit.run(unpack(options)))
