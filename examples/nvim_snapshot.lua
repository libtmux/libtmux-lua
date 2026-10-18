local adapter = require("libtmux.runtime.nvim")

adapter.start(function(runtime)
    local server, err = runtime
        :connect({
            binary = vim.fn.exepath("tmux"),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
        })
        :await()
    if not server then
        return nil, err
    end
    return server:snapshot({ strict = true }):await()
end, function(snapshot, err)
    if err then
        vim.notify(tostring(err), vim.log.levels.ERROR)
        return
    end
    vim.notify(("Panes: %d"):format(#snapshot.panes))
end)
