local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    -- The server is private: its own directory, socket and environment.
    local owned = must(runtime:start_server({ binary = binary }):await())
    local server = owned.server
    local before = must(server:snapshot():await())

    must(server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())
    local after = must(server:snapshot():await())
    print(("sessions: %d, then %d"):format(#before.sessions, #after.sessions))

    must(owned:stop():await())
    return true
end))
