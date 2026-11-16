local adapter = require("libtmux.runtime.luv")
---@diagnostic disable-next-line: different-requires
local uv = require("luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

-- A stand-in for a tmux 3.1 client that rejects -N, so this refusal needs no
-- old tmux build. Its first line uses the interpreter running this program.
local stand_in = os.tmpname()
local file = assert(io.open(stand_in, "w"))
file:write("#!" .. uv.exepath() .. "\n")
file:write('io.stderr:write("tmux: unknown option -- N\\n")\n')
file:write("os.exit(1)\n")
file:close()
assert(uv.fs_chmod(stand_in, 448))

local ok, failure = pcall(function()
    must(adapter.run(function(runtime)
        local owned = must(runtime:start_server({ binary = binary }):await())
        local server, err =
            runtime:connect({ binary = stand_in, socket_path = owned.socket_path }):await()
        assert(server == nil, "a tmux client before 3.2 was accepted")
        err = assert(err, "the refusal carried no error")
        if err.code == "unsupported_version" then
            -- Nothing was sent to the daemon, so there is nothing to undo.
            print(err.code)
            print(err.message)
        else
            error(tostring(err), 0)
        end

        must(owned:stop():await())
        return true
    end))
end)
os.remove(stand_in)
assert(ok, failure)
