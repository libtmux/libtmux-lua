local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_FEATURE_CASE"))

local function work(runtime)
    local server = assert(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
        })
        :await())
    local report
    if mode == "observe" then
        local snapshot =
            assert(server:snapshot({ fields = { sessions = { "id", "name" } } }):await())
        local session = assert(server:handle(snapshot, assert(snapshot.sessions:first())))
        local observer, err = server:observe(session):await()
        if observer then
            assert(observer:close():await())
            report = "RAN"
        else
            report = "REFUSED " .. err.code .. " " .. tostring(err.required) .. " " .. err.effect
        end
    else
        -- LIBTMUX_FEATURE_ARGV is the literal command, each word ended by a pipe.
        local argv = {}
        for word in assert(os.getenv("LIBTMUX_FEATURE_ARGV")):gmatch("([^|]*)|") do
            argv[#argv + 1] = word
        end
        local result, err = server:command(argv):await()
        if result then
            report = "RAN"
        elseif err.code == "unsupported" then
            report = "REFUSED " .. err.code .. " " .. tostring(err.required) .. " " .. err.effect
        else
            report = "RAN " .. err.code
        end
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
            io.stdout:write("FEATURE " .. result .. "\n")
            host.cmd("qa!")
        end
    end)
else
    local result, err = adapter.run(work)
    assert(result, tostring(err))
    print("FEATURE " .. result)
end
