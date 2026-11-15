-- Takes typed text and one key, reports them and prints a screen with history, or reports a respawn
-- and stays: the pane under test_pane.
--   pane.lua TMUX SOCKET REPORT
-- The report is the text and the key in hex separated by NUL, or the working directory and the
-- value of VALUE separated by NUL.
---@type any
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
local binary, socket, report = ...
local common = dofile(debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") .. "/common.lua")
local TEXT = "literal;#{pane_id}\\λ雪"

common.raw()
if os.getenv("PANE_RESPAWN") == "yes" then
    common.report(report, uv.cwd() .. "\0" .. os.getenv("VALUE"))
    common.signal(binary, socket, "pane-respawn-ready")
    common.idle()
    return
end
common.signal(binary, socket, "pane-input-ready")
local text = common.read_exactly(#TEXT)
common.write("TEXT_OK\r\n")
local key = common.read_exactly(1)
common.report(report, text .. "\0" .. key:gsub(".", function(byte)
    return ("%02x"):format(byte:byte())
end))
for index = 0, 39 do
    common.write(("line-%02d trailing  \r\n"):format(index))
end
common.write("RENDER_DONE\r\n")
common.idle()
