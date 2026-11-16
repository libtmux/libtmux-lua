-- Prints bytes in a pane and then stays, waits on a tmux channel or exits: the panes of
-- test_wait_text, test_control, test_observation and test_control_parser.
--   output.lua stay TEXT                    prints TEXT, then echoes typed input until killed
--   output.lua raw TEXT                     the same on a terminal in raw mode
--   output.lua bytes LABEL                  on a raw terminal, prints LABEL and bytes that no text
--                                           decoder passes: NUL, 1, LF, CR, backslash, 255, "DONE"
--   output.lua rows COUNT ROW TEXT          prints COUNT lines of ROW, then TEXT, then stays
--   output.lua wait TEXT TMUX SOCKET NAME   prints TEXT, waits until NAME is signalled, exits 0
local mode = ...
local common = dofile(debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") .. "/common.lua")

if mode == "stay" then
    common.write(select(2, ...))
    common.stay()
elseif mode == "raw" then
    common.raw()
    common.write(select(2, ...))
    common.stay()
elseif mode == "bytes" then
    common.binary()
    common.write(select(2, ...) .. "\0\1\n\r\\\255DONE")
    common.stay()
elseif mode == "rows" then
    local _, count, row, text = ...
    local lines = {}
    for index = 1, tonumber(count) do
        lines[index] = row
    end
    common.write(table.concat(lines, "\n") .. "\n" .. text)
    common.stay()
elseif mode == "wait" then
    local _, text, binary, socket, name = ...
    common.write(text)
    assert(common.run(binary, { "-N", "-S", socket, "wait-for", name }) == 0, "wait-for failed")
else
    error("unknown mode " .. tostring(mode))
end
