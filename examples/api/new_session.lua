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
    local created = must(owned.server
        :new_session({
            name = "demo",
            window_name = "main",
            argv = { "/bin/cat" },
        })
        :await())
    local handles = created.session and created.window and created.pane
    assert(handles, "creation handles are missing")
    local snapshot = must(created.session:snapshot():await())
    assert(snapshot.name == "demo", "created session has the wrong name")
    print("session: " .. snapshot.name)

    must(owned:stop():await())
    return true
end))
