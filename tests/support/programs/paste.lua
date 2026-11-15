-- Takes the bytes a paste delivers, reports them and stays: the pane under test_buffer.
--   paste.lua TMUX SOCKET REPORT MODE
local binary, socket, report, mode = ...
local common = dofile(debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") .. "/common.lua")

common.raw()
if mode == "bracket" then
    common.write("\27[?2004h")
end
common.write("BUFFER_READY")
common.report(report, common.read_until("ENDMARK" .. (mode == "bracket" and "\27[201~" or "")))
common.signal(binary, socket, "buffer-read")
common.stay()
