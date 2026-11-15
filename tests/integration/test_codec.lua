-- Round-trip tmux metadata as bytes over the asynchronous process lane.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

function M.test_metadata_round_trips_every_non_nul_byte()
    fixture.with(function(f)
        local result = f:program("luv", "codec", { LC_ALL = "C", LANG = "C" })
        test.assertStrContains(result.stdout, "metadata codec PASS")
        test.assertStrContains(result.stdout, "typed pane metadata PASS")
    end)
end

return M
