local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_VERSION_CHECK_CASE"))
local options = {
    binary = os.getenv("TMUX_CLIENT_BIN") or assert(os.getenv("TMUX_BIN")),
    socket_path = assert(os.getenv("TMUX_SOCKET")),
}

local function work(runtime)
    if mode == "fence_right" or mode == "fence_wrong" then
        -- Print the argv this library would run; the caller executes it.
        local command = require("libtmux._internal.command")
        local argv = assert(command.prepare({
            binary = options.binary,
            socket = options.socket_path,
            config = "/dev/null",
            no_start = true,
        }, { { "new-session", "-d", "-s", "fenced", "/bin/cat" } }, {
            version = mode == "fence_right" and assert(os.getenv("TMUX_DAEMON_VERSION")) or "9.9",
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
    assert(mode == "admit", "unknown admission case")
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
