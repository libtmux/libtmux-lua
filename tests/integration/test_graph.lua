-- Canonical graph assembly from real linked-window tmux listings.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

function M.test_all_entity_listings_preserve_linked_window_context()
    fixture.with(function(f)
        test.assertStrContains(f:program("luv", "graph").stdout, "graph integration PASS")
    end)
end

return M
