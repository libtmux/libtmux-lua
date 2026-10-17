local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_VERSION_CHECK_CASE"))
local options = {
    binary = os.getenv("TMUX_CLIENT_BIN") or assert(os.getenv("TMUX_BIN")),
    socket_path = assert(os.getenv("TMUX_SOCKET")),
}

local function work(runtime)
    if mode:match("^fence_") then
        -- Print the argv this library would run; the caller executes it.
        local command = require("libtmux._internal.command")
        local argv = assert(command.prepare({
            binary = options.binary,
            socket = options.socket_path,
            config = "/dev/null",
            no_start = true,
        }, { { "new-session", "-d", "-s", "fenced", "/bin/cat" } }, {
            condition = require("libtmux._internal.support.versions").condition({
                version = mode == "fence_wrong_version" and "9.9"
                    or assert(os.getenv("TMUX_DAEMON_VERSION")),
                pid = mode == "fence_wrong_pid" and "1" or assert(os.getenv("TMUX_DAEMON_PID")),
                started = mode == "fence_wrong_start" and "1"
                    or assert(os.getenv("TMUX_DAEMON_START")),
            }),
            marker = "libtmux-version-0123456789abcdef-",
        }))
        io.stdout:write(table.concat(argv, "\0"), "\0\n", mode, " passed\n")
        return mode .. " passed"
    end
    local server, err = runtime:connect(options):await()
    if mode == "refuse" then
        assert(server == nil, "a daemon below the floor was accepted")
        assert(err.code == "unsupported_version" and err.effect == "not_sent", tostring(err))
        return "refuse passed"
    end
    if mode == "snapshot" then
        assert(server, tostring(err))
        local snapshot =
            assert(server:snapshot({ fields = { sessions = { "id", "name" } } }):await())
        local found = false
        for _, session in ipairs(snapshot.sessions) do
            found = found or session.name == assert(os.getenv("LIBTMUX_EXPECT_NAME"))
        end
        assert(found, "snapshot lost the session name")
        assert(server:close():await())
        return "snapshot passed"
    end
    if mode == "observe" then
        assert(server, tostring(err))
        local snapshot =
            assert(server:snapshot({ fields = { sessions = { "id", "name" } } }):await())
        local session = assert(server:handle(snapshot, assert(snapshot.sessions:first())))
        local observer = assert(server:observe(session):await())
        assert(observer:close():await())
        assert(server:close():await())
        return "observe passed"
    end
    assert(mode == "supported", "unknown version check case")
    assert(server, tostring(err))
    local created
    created, err = server:command({ "new-session", "-d", "-s", "supported", "/bin/cat" }):await()
    assert(created, tostring(err))
    assert(server:close():await())
    return "supported passed"
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
