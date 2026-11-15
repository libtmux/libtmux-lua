-- Prints a screen with history, or a pending escape sequence, once it is told to: the pane under
-- test_capture.
--   capture.lua TMUX SOCKET CASE
local binary, socket, case = ...
local common = dofile(debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") .. "/common.lua")

common.raw()
common.signal(binary, socket, "capture-input-ready")
common.read(1)
if case:match("pending$") then
    common.write("PENDING_READY\27[")
else
    for index = 0, 39 do
        common.write(("line-%02d\r\n"):format(index))
    end
    common.write("\27]8;;https://example.invalid/\27\\link\27]8;;\27\\\r\nCAPTURE_READY\r\n")
end
common.idle()
