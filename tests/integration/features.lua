local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_FEATURE_CASE"))

local function work(runtime)
    local server = assert(runtime
        :connect({
            binary = os.getenv("TMUX_CLIENT_BIN") or assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
        })
        :await())
    local report
    if mode == "capabilities" then
        local discovered = assert(server:capabilities():await())
        assert(discovered.version == os.getenv("TMUX_DAEMON_VERSION"), discovered.version)
        local deletion = assert(discovered.features["buffer-delete-named"])
        assert(deletion.since == "3.4" and deletion.handling == "refuse")
        assert(discovered.features["unknown-feature"] == nil)
        local expected = assert(os.getenv("LIBTMUX_EXPECT_DELETE")) == "yes"
        assert(deletion.supported == expected, "feature decision disagrees with daemon")
        deletion.since, deletion.supported = "1.0", true
        deletion.commands[1].flags[1] = "-not-a-flag"
        assert(server:set_buffer("capability-check", "owned"):await())
        local deleted, err = server:delete_buffer("capability-check"):await()
        if expected then
            assert(deleted, tostring(err))
        else
            assert(deleted == nil and err.code == "unsupported" and err.effect == "not_sent")
        end
        local again = assert(server:capabilities():await())
        assert(again.features["buffer-delete-named"].since == "3.4")
        assert(again.features["buffer-delete-named"].supported == expected)
        assert(again.features["buffer-delete-named"].commands[1].flags[1] == "-b")
        assert(server:close():await())
        local closed, closed_error = server:capabilities():await()
        assert(closed == nil and closed_error.code == "closed")
        assert(discovered.version == os.getenv("TMUX_DAEMON_VERSION"))
        return "DISCOVERED " .. discovered.version
    elseif mode == "observe" then
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
