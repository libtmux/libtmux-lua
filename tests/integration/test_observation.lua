-- Public session leases share a native client and preserve borrowed topology.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local repo = require("support.repo")
local M = {}

local TOPOLOGY = "#{session_id};#{pane_id};#{window_id};#{window_width};#{window_height}"

fixture.each_host(M, "shared_client_streams_and_reopen_after_native_cleanup", function(host)
    fixture.with(function(f)
        fixture.require_control(f)
        f:run("resize-window", "-t", "fixture:0", "-x", "121", "-y", "37")
        local before = f:out("display-message", "-p", "-t", "fixture:0.0", TOPOLOGY)
        local result = f:program(host, "observation", {
            LIBTMUX_OUTPUT_SCRIPT = repo.root .. "/tests/support/programs/output.lua",
        })
        test.assertStrContains(result.stdout, "shared observation passed")
        test.assertEquals(f:out("display-message", "-p", "-t", "fixture:0.0", TOPOLOGY), before)
        test.assertEquals(f:out("list-clients"), "")
    end)
end)

return M
