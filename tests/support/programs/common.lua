-- What the programs in this directory share. They run in a pane, or as a child of the library,
-- under whichever Lua the tests select, so they use luv and nothing that only LuaJIT has.
---@type any
---@diagnostic disable-next-line: different-requires
local uv = require("luv")

local M = {}

--- Puts the terminal on standard input in raw mode: no echo, no line editing. The handle stays
--- referenced, because closing it would restore the terminal, and blocking, because libuv makes
--- the terminal non-blocking and the reads below and a program run on it expect to wait.
function M.raw()
    M.tty = assert(uv.new_tty(0, true))
    assert(M.tty:set_mode(1))
    assert(M.tty:set_blocking(true))
end

--- Puts the terminal on standard input in binary mode: no echo, no line editing and no output
--- translation, so what the program writes reaches tmux byte for byte. Raw mode keeps libuv's
--- translation of line feeds to a carriage return and a line feed.
function M.binary()
    M.tty = assert(uv.new_tty(0, true))
    assert(M.tty:set_mode(2))
    assert(M.tty:set_blocking(true))
end

--- Reads what is available from standard input, up to `count` bytes. Nil at the end of input.
---@param count integer
---@return string?
function M.read(count)
    local data = uv.fs_read(0, count, -1)
    if data == nil or data == "" then
        return nil
    end
    return data
end

--- Reads exactly `count` bytes from standard input.
---@param count integer
---@return string
function M.read_exactly(count)
    local value = ""
    while #value < count do
        value = value .. assert(M.read(count - #value), "input ended")
    end
    return value
end

--- Reads from standard input until it ends in `suffix`.
---@param suffix string
---@return string
function M.read_until(suffix)
    local value = ""
    while value:sub(-#suffix) ~= suffix do
        value = value .. assert(M.read(1024), "input ended")
    end
    return value
end

---@param data string
function M.write(data)
    local written = 0
    while written < #data do
        written = written + assert(uv.fs_write(1, data:sub(written + 1), -1))
    end
end

--- Writes a file in one piece.
---@param path string
---@param data string
function M.report(path, data)
    local handle = assert(io.open(path, "wb"))
    assert(handle:write(data))
    assert(handle:close())
end

--- Runs a program with this one's terminal and waits for it. Returns its exit status.
---@param command string
---@param arguments string[]
---@return integer
function M.run(command, arguments)
    local status
    local handle, failure = uv.spawn(
        command,
        { args = arguments, stdio = { 0, 1, 2 } },
        function(code)
            status = code
        end
    )
    assert(handle, failure)
    while not status do
        uv.run("once")
    end
    handle:close()
    return status
end

--- Signals a tmux wait-for channel, so the test that waits on it goes on.
---@param binary string
---@param socket string
---@param name string
function M.signal(binary, socket, name)
    assert(M.run(binary, { "-N", "-S", socket, "wait-for", "-S", name }) == 0, "wait-for failed")
end

--- Keeps the pane alive, and echoing what is typed, until it is killed.
function M.stay()
    M.run("/bin/cat", {})
end

--- Blocks until standard input ends.
function M.idle()
    while M.read(4096) do
    end
end

return M
