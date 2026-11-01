-- Connects with only the options and environment the test chose, and reports
-- which server answered by the names of its sessions and its socket path.
local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local options = {
    binary = assert(os.getenv("TMUX_BIN")),
    -- Not a variable the library reads: the test names an explicit socket this way.
    socket_path = os.getenv("LIBTMUX_TEST_EXPLICIT_SOCKET"),
}

local function work(runtime)
    local server, err = runtime:connect(options):await()
    if not server then
        return "error: " .. err.code
    end
    local snapshot, snapshot_error = server:snapshot():await()
    assert(snapshot, tostring(snapshot_error))
    local names = {}
    for _, session in ipairs(snapshot.sessions) do
        names[#names + 1] = session.name
    end
    table.sort(names)
    local socket = assert(server:command({ "display-message", "-p", "#{socket_path}" }):await())
    local report = "sessions: " .. table.concat(names, ",") .. "\nsocket: " .. socket.stdout
    if os.getenv("LIBTMUX_TEST_OBSERVE") then
        -- The control client names no socket either: the server that counts it is the one reached.
        local session = assert(server:handle(snapshot, assert(snapshot.sessions:first())))
        local observation = assert(server:observe(session):await())
        local clients =
            assert(server:command({ "list-clients", "-F", "#{client_control_mode}" }):await())
        report = report .. "control clients: " .. #clients.stdout:gsub("[^\n]", "") .. "\n"
        assert(observation:close():await())
    end
    assert(server:close():await())
    return report
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
    local result, err = adapter.run(work)
    assert(result, tostring(err))
    print(result)
end
