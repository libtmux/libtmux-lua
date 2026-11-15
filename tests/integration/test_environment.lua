-- Persistent environment records and ambiguous native output on owned servers.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

local function run_case(mode, host)
    fixture.with({ env = { LC_ALL = "C", LANG = "C" } }, function(f)
        local result = f:program(host, "environment", { LIBTMUX_ENVIRONMENT_CASE = mode })
        test.assertStrContains(result.stdout, ("public environment %s PASS"):format(mode))
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:out("list-clients"), "")
    end)
end

fixture.each_host(M, "values_visibility_removal_and_global_fallback", function(host)
    run_case("values", host)
end)
fixture.each_host(M, "hidden_listing_and_ambiguous_removed_names", function(host)
    run_case("listing", host)
end)

return M
