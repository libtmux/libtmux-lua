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
    local owned = must(runtime:start_server({ binary = binary }):await())
    local session = { name = "demo", argv = { "/bin/cat" } }
    must(owned.server:new_session(session):await())

    -- A second handle reaches the same daemon and leaves it running on close.
    local target = { binary = binary, socket_path = owned.socket_path }
    local server = must(runtime:connect(target):await())
    local snapshot = must(server:snapshot({ strict = true }):await())
    local demo = snapshot.sessions:where({ name = "demo" })
    assert(#demo == 1, "demo session is missing")
    print("connected")

    must(server:close():await())
    must(owned:stop():await())
    return true
end))
