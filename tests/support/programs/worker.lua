-- Holds a fixture until it is cancelled: the worker under test_fixture. It prints the fixture's
-- directory, socket, server pid and first pane pid, one per line, and exits with 143 once SIGTERM
-- has unwound the fixture.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
package.path = here .. "/../../../scripts/?.lua;" .. here .. "/../../../?.lua;" .. package.path
require("support.repo").use_rocks()
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")

child.watch_signals()
local ok, failure = pcall(fixture.with, function(f)
    io.write(f.path, "\n", f.socket, "\n", f.server_pid, "\n", f.pane_pids[1], "\n")
    io.flush()
    child.pump(function()
        return false
    end, 60)
end)
os.exit(ok and 0 or (failure == child.CANCELLED and 143 or 1))
