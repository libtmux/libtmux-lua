-- Reports where it was started and stays: the pane under test_domain.
--   created.lua TMUX SOCKET REPORT ARGUMENT...
-- The report holds the working directory, the value of LIBTMUX_LITERAL and each argument, separated
-- by NUL.
---@type any
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
local binary, socket, report = ...
local common = dofile(debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") .. "/common.lua")

local fields = { uv.cwd(), os.getenv("LIBTMUX_LITERAL") }
for index = 4, select("#", ...) do
    fields[#fields + 1] = (select(index, ...))
end
common.report(report, table.concat(fields, "\0"))
common.signal(binary, socket, "libtmux-created-ready")
common.idle()
