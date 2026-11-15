-- Public live queries preserve linked context and hydrate required fields.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

fixture.each_host(M, "public_candidates_and_full_hydration", function(host)
    fixture.with(function(f)
        f:run("split-window", "-d", "-h", "-t", "fixture:0", "exec /bin/cat")
        f:run("split-window", "-d", "-v", "-t", "fixture:0.1", "exec /bin/cat")
        f:run("link-window", "-s", "fixture:0", "-t", "fixture:9")
        test.assertStrContains(f:program(host, "live_query").stdout, "public live query PASS")
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:try("has-session", "-t", "$0").code, 0)
    end)
end)

return M
