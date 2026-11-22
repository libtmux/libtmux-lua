local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local session = { name = "demo", argv = { "/bin/sh" } }
    local created = must(owned.server:new_session(session):await())
    local pane = created.pane

    -- The shell echoes what is typed, so print the needle from two pieces.
    must(pane:send_text("printf '%s%s\\n' 'lua wait ' 'ready'"):await())
    must(pane:send_keys({ "Enter" }):await())
    local wait = pane:wait_for_text("lua wait ready", { timeout = 5000 })
    local found = must(wait:await())
    assert(found.text:find("lua wait ready", 1, true))
    print("lua wait ready")

    must(owned:stop():await())
    return true
end))
