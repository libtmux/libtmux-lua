local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function work(runtime)
    local server = assert(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
        })
        :await())
    local snapshot = assert(server
        :snapshot({
            fields = {
                sessions = { "id", "name" },
                windows = { "id" },
                panes = { "id", "window_id", "index" },
                window_links = { "session_id", "window_id", "index" },
                clients = { "name", "tty", "session_name" },
                buffers = { "name" },
            },
        })
        :await())
    local session = assert(server:handle(snapshot, assert(snapshot.sessions:first())))
    local pane = assert(server:handle(snapshot, assert(snapshot.panes:first())))
    local first, second = server:observe(session), server:observe(session)
    local a, b = assert(first:await()), assert(second:await())
    local generation = assert(a:coverage()).generation
    assert(rawequal(generation, assert(b:coverage()).generation))
    local clients =
        assert(server:command({ "list-clients", "-F", "#{client_control_mode}" }):await())
    assert(clients.stdout == "1\n", clients.stdout)
    local aw = assert(a:watch_pane(pane):await())
    local bw = assert(b:watch_pane(pane):await())
    local format = assert(b:subscribe_format(pane, { "title", "dead" }):await())
    assert(format:close():await())
    assert(
        pane:respawn({ kill = true, shell = "stty raw -echo; printf 'READY'; exec /bin/cat" })
            :await()
    )
    for _, watch in ipairs({ aw, bw }) do
        local bytes = ""
        repeat
            local event = assert(watch:next({ timeout = 750 }):await())
            bytes = bytes .. event.data
            assert(rawequal(event.generation, generation))
        until bytes:find("READY", 1, true)
    end
    local canceled_read = aw:next()
    assert(a:close():await())
    local ended, ended_error = canceled_read:await()
    assert(ended == nil and ended_error == nil, tostring(ended_error))
    assert(pane:send_text("INPUT"):await())
    assert(pane:send_keys({ "Enter" }):await())
    local bytes = ""
    repeat
        bytes = bytes .. assert(bw:next({ timeout = 750 }):await()).data
    until bytes:find("INPUT\r", 1, true)
    local final_read = bw:next()
    assert(b:close():await())
    ended, ended_error = final_read:await()
    assert(ended == nil and ended_error == nil, tostring(ended_error))
    clients = assert(server:command({ "list-clients", "-F", "#{client_control_mode}" }):await())
    assert(clients.stdout == "", clients.stdout)
    local reopened = assert(server:observe(session):await())
    assert(not rawequal(generation, assert(reopened:coverage()).generation))
    -- Root return must close the remaining observer without explicit close.
    return "shared observation passed"
end

if host then
    adapter.start(work, function(value, err)
        if err then
            io.stderr:write(tostring(err), "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(value, "\n")
            host.cmd("qa!")
        end
    end)
else
    local value, err = adapter.run(work)
    assert(value, tostring(err))
    io.stdout:write(value, "\n")
end
