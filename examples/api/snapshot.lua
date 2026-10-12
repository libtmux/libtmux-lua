local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

local binary =
    assert(os.getenv("TMUX_BIN"), "set TMUX_BIN to an absolute tmux executable")
local socket =
    assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to the private socket")

must(adapter.run(function(runtime)
    local server =
        must(runtime:connect({ binary = binary, socket_path = socket }):await())
    local session_options = {
        name = "demo",
        window_name = "main",
        argv = { "/bin/cat" },
    }
    must(server:new_session(session_options):await())
    local snapshot = must(server:snapshot({ strict = true }):await())
    local sessions, windows = {}, {}
    for _, session in ipairs(snapshot.sessions) do
        sessions[#sessions + 1] = session.name
    end
    for _, window in ipairs(snapshot.windows) do
        windows[#windows + 1] = window.name
    end
    table.sort(sessions)
    table.sort(windows)
    assert(
        #snapshot.sessions == 2
            and #snapshot.windows == 2
            and #snapshot.panes == 2
    )
    print("sessions: " .. table.concat(sessions, ", "))
    print("windows: " .. table.concat(windows, ", "))
    print("panes: " .. #snapshot.panes)

    must(server:close():await())
    return true
end))
