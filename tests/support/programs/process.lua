-- The child programs that tests/integration/process.lua runs through the library, each a byte-exact
-- stand-in for a command.
--   process.lua arguments ARGUMENT...  writes the arguments joined by "|"
--   process.lua echo                   copies standard input to standard output, writes "err\0\255"
--                                      to standard error
--   process.lua partial                writes "partial" and exits with status 17
--   process.lua drain                  exits at once and leaves a descendant that holds standard
--                                      output until LIBTMUX_RELEASE_FIFO is written to
-- The descendant records its pid in LIBTMUX_DESCENDANT_PID and writes it to standard output.
-- Neovim starts its children without LUA_CPATH, so the tests pass it on under another name.
local cpath = os.getenv("LIBTMUX_TEST_LUA_CPATH")
if cpath then
    package.cpath = cpath .. ";" .. package.cpath
end
---@type any
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
local mode = ...

if mode == "arguments" then
    io.stdout:write(table.concat(arg, "|", 2))
    io.stdout:flush()
elseif mode == "echo" then
    local data = uv.fs_read(0, 100, -1) or ""
    io.stdout:write(data)
    io.stdout:flush()
    io.stderr:write("err\0\255")
    io.stderr:flush()
elseif mode == "partial" then
    io.stdout:write("partial")
    io.stdout:flush()
    os.exit(17)
elseif mode == "drain" then
    local handle, failure = uv.spawn(arg[-1], {
        args = { arg[0], "descendant" },
        stdio = { 0, 1, 2 },
        detached = true,
    }, function() end)
    assert(handle, failure)
    handle:unref()
    os.exit(0)
elseif mode == "descendant" then
    -- luv returns the pid as a float, which Lua 5.4 and later print with a trailing ".0".
    local pid = ("%d"):format(uv.os_getpid())
    local record = assert(io.open(assert(os.getenv("LIBTMUX_DESCENDANT_PID")), "w"))
    record:write(pid)
    record:close()
    io.stdout:write(pid, "\n")
    io.stdout:flush()
    -- Opening a FIFO for reading waits for its writer.
    local release = assert(io.open(assert(os.getenv("LIBTMUX_RELEASE_FIFO")), "rb"))
    local _ = release:read(1)
    release:close()
else
    error("unknown program " .. tostring(mode))
end
