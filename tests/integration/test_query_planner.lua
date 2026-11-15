-- Compare bounded native query plans with complete local snapshot evaluation.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

function M.test_native_candidates_preserve_local_predicates_and_relations()
    fixture.with(function(f)
        f:run("split-window", "-d", "-h", "-t", "fixture:0", "exec /bin/cat")
        f:run("split-window", "-d", "-v", "-t", "fixture:0.1", "exec /bin/cat")
        local panes = {}
        for pane in f:out("list-panes", "-t", "fixture:0", "-F", "#{pane_id}"):gmatch("[^\n]+") do
            panes[#panes + 1] = pane
        end
        local titles = { panes[1], "needle", "other" }
        for index, pane in ipairs(panes) do
            f:run("select-pane", "-t", pane, "-T", titles[index])
        end
        f:run("link-window", "-s", "fixture:0", "-t", "fixture:9")
        f:run("set-buffer", "-b", "query-buffer", "bytes")
        local result = f:program("luv", "query_planner")
        test.assertStrContains(result.stdout, "live query planner PASS")
        test.assertEquals(f:pins(), {})
    end)
end

return M
