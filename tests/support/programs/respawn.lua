-- Reports the environment and arguments a respawned window was given, and stays: the window under
-- test_topology.
--   respawn.lua TMUX SOCKET REPORT ARGUMENT...
-- The report is the values of SCOPE and VALUE, then each argument, separated by NUL.
local binary, socket, report = ...
local common = dofile(debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") .. "/common.lua")

local fields = { os.getenv("SCOPE"), os.getenv("VALUE") }
for index = 4, select("#", ...) do
    fields[#fields + 1] = (select(index, ...))
end
common.report(report, table.concat(fields, "\0"))
common.signal(binary, socket, "window-ready")
common.stay()
