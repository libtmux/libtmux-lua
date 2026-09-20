local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_SNAPSHOT_CASE"))

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

local function work(runtime)
    local server = must(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
            config_path = "/dev/null",
        })
        :await())
    local snapshot = must(server:snapshot({ strict = true }):await())
    assert(snapshot.complete and snapshot.verification.passes == 1)
    assert(snapshot.capabilities.version == os.getenv("TMUX_DAEMON_VERSION"))
    assert(snapshot.acquisition.finished >= snapshot.acquisition.started)
    assert(#snapshot.projections.client > 0)
    if mode == "empty" then
        assert(#snapshot.sessions == 0 and #snapshot.panes == 0)
        assert(#snapshot.buffers == 1 and snapshot.buffers[1].name == "retained")
    else
        assert(#snapshot.sessions == 1 and #snapshot.windows == 1 and #snapshot.panes == 1)
        assert(#snapshot.window_links == 2 and #snapshot.raw.windows == 2)
        assert(#snapshot.raw.panes == 2)
        local pane = snapshot.panes[1]
        assert(#pane.window.window_links == 2)
        local original = pane.id
        local refreshed = must(server:snapshot({ fields = { panes = { "id" } } }):await())
        assert(refreshed.panes[1] ~= pane)
        pane.id, pane.ref.id = "%999", "%998"
        assert(refreshed.panes[1].id == original)
        local handle = must(server:handle(snapshot, pane))
        assert(handle:reference().id == original)
        local live = must(handle:snapshot():await())
        assert(live.id == original)
        assert(refreshed.panes[1].window_id == "@0")
        assert(#refreshed.requested_projections.pane == 1)
        assert(#refreshed.projections.pane == 3)
        local ok, err = pcall(function()
            refreshed.panes:where({ title = "unloaded" })
        end)
        assert(not ok and type(err) == "table" and rawget(err, "code") == "unloaded_field")
    end
    must(server:close():await())
    local closed, err = server:snapshot():await()
    assert(closed == nil and err.code == "closed")
    return "public snapshot " .. mode .. " PASS"
end

if host then
    adapter.start(work, function(result, err)
        if not result then
            io.stderr:write(tostring(err) .. "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(result .. "\n")
            host.cmd("qa!")
        end
    end)
else
    print(must(adapter.run(work)))
end
