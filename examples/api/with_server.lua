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
    -- The server stops when the body returns, fails or raises.
    local count = must(runtime
        :with_server({ binary = binary }, function(server)
            must(server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())
            local snapshot = must(server:snapshot():await())
            return #snapshot.sessions
        end)
        :await())
    print("sessions: " .. count)
    return true
end))
