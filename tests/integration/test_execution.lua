-- Public command wiring preserves raw exits and indexed batch failures.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

fixture.each_host(M, "raw_failures_groups_and_independent_batch", function(host)
    fixture.with(function(f)
        test.assertStrContains(f:program(host, "execution").stdout, "public execution passed")
        test.assertEquals(f:pins(), {})
    end)
end)

return M
