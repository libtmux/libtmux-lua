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
    must(owned.server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())

    -- A second handle reaches the same daemon. Closing it leaves the daemon running.
    local server =
        must(runtime:connect({ binary = binary, socket_path = owned.socket_path }):await())
    local snapshot = must(server:snapshot({ strict = true }):await())
    assert(#snapshot.sessions:where({ name = "demo" }) == 1, "demo session is missing")
    print("connected")

    must(server:close():await())
    must(owned:stop():await())
    return true
end))
