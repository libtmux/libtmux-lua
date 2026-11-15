local adapter = require("libtmux.runtime.nvim")

adapter.start(function(runtime)
    local owned, err = runtime:start_server({ binary = vim.fn.exepath("tmux") }):await()
    if not owned then
        return nil, err
    end
    local created
    created, err = owned.server:new_session({ name = "demo", argv = { "/bin/cat" } }):await()
    local snapshot
    if created then
        snapshot, err = owned.server:snapshot({ strict = true }):await()
    end
    local stopped, stop_err = owned:stop():await()
    if not snapshot then
        return nil, err
    end
    if not stopped then
        return nil, stop_err
    end
    return snapshot
end, function(snapshot, err)
    if err then
        vim.notify(tostring(err), vim.log.levels.ERROR)
        return
    end
    vim.notify(("Panes: %d"):format(#snapshot.panes))
end)
