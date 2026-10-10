local host = rawget(_G, "vim")
-- luv is the native host module, distinct from libtmux.runtime.luv.
---@diagnostic disable-next-line: different-requires
local uv = host and (host.uv or host.loop) or require("luv")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_LIFECYCLE_MODE"))

local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end

local launched, cleaned = 0, false
local spawn = uv.spawn
local function entries(sequence)
    local result = {}
    for _, entry in ipairs(sequence) do
        local key, value = entry:match("^([^=]+)=(.*)$")
        result[key] = value
    end
    return result
end

local function work(runtime)
    local request = runtime:connect()
    must(uv.os_setenv("LIBTMUX_SOCKET_PATH", "/invalid-after-capture/socket"))
    must(uv.os_setenv("LIBTMUX_SOCKET_NAME", "invalid/after/capture"))
    must(uv.os_setenv("TMUX_TMPDIR", "/invalid-after-capture/root"))
    must(uv.os_setenv("LIBTMUX_CLIENT_MARKER", "after"))
    must(uv.os_setenv("PATH", "/invalid-after-capture/path"))
    uv.spawn = function(binary, spec, callback)
        local env = entries(assert(spec.env, "client inherited the live host environment"))
        assert(env.LIBTMUX_CLIENT_MARKER == "before")
        assert(not env.TMUX and not env.TMUX_PANE)
        assert(env.PATH ~= "/invalid-after-capture/path")
        launched = launched + 1
        return spawn(binary, spec, callback)
    end
    local server = must(request:await())
    local created =
        must(server:new_session({ name = "captured-example", argv = { "/bin/cat" } }):await())
    must(runtime:defer(function()
        must(created.session:kill():await())
        cleaned = true
    end))
    must(server:command({ "display-message", "-p", "captured" }):await())
    local observer = must(server:observe(created.session):await())
    must(observer:close():await())
    if mode == "body" then
        error("injected lifecycle body error", 0)
    elseif mode == "cancel" then
        local timer = uv.new_timer()
        timer:start(0, 0, function()
            timer:close()
            if host then
                host.schedule(function()
                    runtime:close("injected lifecycle cancellation")
                end)
            else
                runtime:close("injected lifecycle cancellation")
            end
        end)
        server:command({ "wait-for", "never-signalled" }):await()
    end
    return true
end

local function finish(value, err)
    uv.spawn = spawn
    assert(cleaned, "deferred session cleanup did not run")
    assert(launched >= 6, "binding, commands and observation were not exercised")
    if mode == "normal" then
        must(value, err)
    else
        assert(err and (err.code == "task_error" or err.code == "cancelled"), tostring(err))
    end
    io.stdout:write("captured lifecycle " .. mode .. " PASS\n")
end

if host then
    adapter.start(work, function(value, err)
        local ok, failure = pcall(finish, value, err)
        if not ok then
            io.stderr:write(tostring(failure), "\n")
        end
        host.cmd(ok and "qa!" or "cquit 1")
    end)
else
    finish(adapter.run(work))
end
