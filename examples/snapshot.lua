local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

must(adapter.run(function(runtime)
    local server = must(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN"), "set TMUX_BIN to an absolute tmux executable"),
            socket_path = assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to an explicit socket"),
        })
        :await())
    local snapshot = must(server:snapshot({ strict = true }):await())
    for _, pane in ipairs(snapshot.panes) do
        io.stdout:write(pane.id, "\t", pane.window_id, "\n")
    end
    must(server:close():await())
    return true
end))
