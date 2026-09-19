local endpoints = require("libtmux._internal.endpoint")
local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_ENDPOINT_CASE"))
local options = {
    binary = assert(os.getenv("TMUX_BIN")),
    socket = assert(os.getenv("TMUX_SOCKET")),
    config = "/dev/null",
}
local left_for_runtime

local function ready(runtime, evidence)
    io.stdout:write("READY " .. evidence.pid .. " " .. evidence.started .. "\n")
    io.stdout:flush()
    local released, err = runtime
        :_request({
            bytes = 0,
            start = function(settle, retire)
                local pipe = assert(runtime._driver.uv.new_pipe(false))
                assert(pipe:open(0))
                local closing = false
                local function close()
                    if not closing then
                        closing = true
                        pipe:close(retire)
                    end
                end
                assert(pipe:read_start(function(read_err, data)
                    if read_err then
                        settle(nil, read_err)
                    elseif data then
                        settle(true)
                    else
                        settle(nil, "fixture closed before releasing endpoint probe")
                    end
                    close()
                end))
                return close
            end,
        })
        :await()
    assert(released, tostring(err))
end

local function work(runtime)
    if mode == "cancel_bind" then
        local uv = runtime._driver.uv
        local original = uv.fs_mkdtemp
        local binding
        uv.fs_mkdtemp = function(template, callback)
            return original(template, function(err, directory)
                uv.fs_mkdtemp = original
                assert(directory, tostring(err))
                assert(binding:cancel())
                callback(err, directory)
            end)
        end
        binding = endpoints.bind(runtime, options)
        local bound, err = binding:await()
        assert(bound == nil and err.code == "cancelled")
        return mode .. " passed"
    end
    local bound, err = endpoints.bind(runtime, options):await()
    assert(bound, tostring(err))
    local evidence = assert(bound:evidence())
    assert(evidence.socket == options.socket)
    assert(evidence.version == os.getenv("TMUX_DAEMON_VERSION"))
    assert(evidence.pid:match("^%d+$") and evidence.started:match("^%d+$"))
    local result
    result, err = bound:execute({ "display-message", "-p", "#{session_id} #{pane_id}" }):await()
    assert(result and result.stdout == "$0 %0\n", tostring(err))
    if mode == "replacement" or mode == "dead" then
        ready(runtime, evidence)
        result, err = bound:execute({ "new-session", "-d", "-s", "must-not-create" }):await()
        assert(result == nil, "stale endpoint created a session")
        assert(err.code == "stale_generation" and err.effect == "not_sent", tostring(err))
        assert(bound:generation() == nil)
    elseif mode == "normal" then
        local generation = assert(bound:generation())
        result, err = bound:execute({ "display-message", "-p", "#{pid}" }):await()
        assert(result and result.stdout == evidence.pid .. "\n", tostring(err))
        assert(bound:generation() == generation)
        result, err = bound:execute({ "has-session", "-t", "libtmux-missing-session" }):await()
        assert(result == nil and err.code == "exit_failed" and err.effect == "completed")
        assert(bound:generation() == generation)
        left_for_runtime = assert(endpoints.bind(runtime, options):await())
    else
        error("unknown endpoint integration case")
    end
    local closed = bound:close()
    assert(closed == bound:close())
    assert(closed:await())
    assert(bound:generation() == nil)
    return mode .. " passed"
end

if host then
    adapter.start(work, function(result, err)
        if not result then
            io.stderr:write(tostring(err) .. "\n")
            host.cmd("cquit 1")
        else
            assert(not left_for_runtime or left_for_runtime:generation() == nil)
            io.stdout:write(result .. "\n")
            host.cmd("qa!")
        end
    end)
else
    local result, err = adapter.run(work)
    assert(result, tostring(err))
    assert(not left_for_runtime or left_for_runtime:generation() == nil)
    print(result)
end
