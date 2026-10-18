local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

local socket = assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to the private socket")

-- A stand-in for a tmux 3.1 server: it answers the version check with the
-- usage error that release prints, so the refusal needs no old tmux build.
local stand_in = os.tmpname()
local file = assert(io.open(stand_in, "w"))
file:write("#!/bin/sh\necho 'usage: run-shell [-b] [-t target-pane] shell-command' >&2\nexit 1\n")
file:close()
assert(os.execute("chmod 700 " .. stand_in))

local ok, failure = pcall(function()
    must(adapter.run(function(runtime)
        local server, err = runtime:connect({ binary = stand_in, socket_path = socket }):await()
        assert(server == nil, "a tmux before 3.2 was accepted")
        err = assert(err, "the refusal carried no error")
        if err.code == "unsupported_version" then
            -- Nothing was sent to the daemon, so there is nothing to undo.
            print(err.code)
            print(err.message)
        else
            error(tostring(err), 0)
        end
        return true
    end))
end)
os.remove(stand_in)
assert(ok, failure)
