local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function must(value, err)
    if err then
        error(tostring(err), 2)
    end
    return value
end

local function work(runtime)
    local server = must(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
        })
        :await())
    local selector = {
        name = assert(os.getenv("LIBTMUX_CLIENT_NAME")),
        tty = assert(os.getenv("LIBTMUX_CLIENT_NAME")),
    }
    local destination =
        must(server:new_session({ name = "client-target", argv = { "/bin/cat" } }):await()).session
    local value, err = destination:attach():await()
    assert(value == nil and err and err.code == "unsupported_tty" and err.effect == "not_sent")
    must(destination:set_environment("DISPLAY", "preserve-this"):await())
    value, err = server:detach_client({ name = "client-missing", tty = "" }):await()
    assert(value == nil and err and err.code == "missing_target" and err.effect == "not_sent")
    local cancelled = server:detach_client(selector)
    cancelled:cancel()
    value, err = cancelled:await()
    assert(value == nil and err and err.code == "cancelled" and err.effect == "not_sent")
    must(server:switch_client(selector, destination):await())
    local moved =
        must(server:command({ "list-clients", "-F", "#{client_name};#{client_session}" }):await())
    assert(moved.stdout:find(selector.name .. ";client-target\n", 1, true))
    assert(must(destination:get_environment("DISPLAY"):await()).value == "preserve-this")
    must(server:switch_client(selector, destination, { update_environment = true }):await())
    assert(must(destination:get_environment("DISPLAY"):await()).value == "client-display")
    must(server:detach_client(selector):await())
    must(server:close():await())
    return "public client PASS"
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
    end, { max_active = 1 })
else
    print(must(adapter.run(work, { max_active = 1 })))
end
