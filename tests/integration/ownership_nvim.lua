local host = assert(rawget(_G, "vim"))
local adapter = require("libtmux.runtime.nvim")
local uv = host.uv or host.loop
local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end
local marker = { code = "body_failure", message = "Neovim body failure" }
local watchdog = uv.new_timer()
watchdog:start(2000, 0, function()
    host.schedule(function()
        host.cmd("cquit 1")
    end)
end)
adapter.start(function(runtime)
    local server = must(runtime:connect():await())
    local value, err = server
        :with_session({ name = "nvim-body", argv = { "/bin/cat" } }, function()
            error(marker, 0)
        end)
        :await()
    assert(not value and err == marker)
    local request
    request = server:with_session({ name = "nvim-cancel", argv = { "/bin/cat" } }, function()
        host.schedule(function()
            request:cancel("host cancellation")
        end)
        return server:command({ "wait-for", "nvim-never" }):await()
    end)
    value, err = request:await()
    assert(not value and err.code == "cancelled")
    local listing = must(server:command({ "list-sessions", "-F", "#{session_name}" }):await())
    assert(listing.stdout == "fixture\n")
    return true
end, function(value, err)
    watchdog:stop()
    watchdog:close()
    assert(not host.in_fast_event())
    if not value then
        io.stderr:write(tostring(err), "\n")
        host.cmd("cquit 1")
        return
    end
    print("Neovim ownership body and cancellation PASS")
    host.cmd("qa!")
end)
