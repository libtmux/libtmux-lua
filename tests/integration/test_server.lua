-- Public snapshot capture preserves links and sessionless daemon buffers.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

local function run_case(mode, host)
    fixture.with(function(f)
        local version = f:version()
        if mode == "empty" then
            f:run("set-option", "-s", "exit-empty", "off")
            f:run("set-buffer", "-b", "retained", "bytes")
            f:run("kill-session", "-t", "$0")
        else
            f:run("link-window", "-s", "@0", "-t", "$0:9")
        end
        local result = f:program(
            host,
            "server",
            { TMUX_DAEMON_VERSION = version, LIBTMUX_SNAPSHOT_CASE = mode }
        )
        test.assertStrContains(result.stdout, ("public snapshot %s PASS"):format(mode))
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:version(), version)
    end)
end

fixture.each_host(M, "repeated_window_links_and_explicit_refresh", function(host)
    run_case("linked", host)
end)
fixture.each_host(M, "sessionless_daemon_keeps_named_buffers", function(host)
    run_case("empty", host)
end)

return M
