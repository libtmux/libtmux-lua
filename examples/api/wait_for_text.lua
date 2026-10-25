local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

local binary = assert(os.getenv("TMUX_BIN"), "set TMUX_BIN to an absolute tmux executable")
local socket = assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to the private socket")

must(adapter.run(function(runtime)
    local server = must(runtime:connect({ binary = binary, socket_path = socket }):await())
    local created = must(server:new_session({ name = "demo", argv = { "/bin/sh" } }):await())
    local pane = created.pane

    -- The shell echoes what is typed, so print the needle from two pieces.
    must(pane:send_text("printf '%s%s\\n' 'lua wait ' 'ready'"):await())
    must(pane:send_keys({ "Enter" }):await())
    local found = must(pane:wait_for_text("lua wait ready", { timeout = 5000 }):await())
    assert(found.text:find("lua wait ready", 1, true))
    print("lua wait ready")

    must(server:close():await())
    return true
end))
