local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    must(owned.server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())
    local snapshot = must(owned.server:snapshot({ strict = true }):await())
    for _, pane in ipairs(snapshot.panes) do
        io.stdout:write(pane.id, "\t", pane.window_id, "\n")
    end
    must(owned:stop():await())
    return true
end))
