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
    must(pane:send_text("printf '%s%s\\n' 'lua input ' 'ready'"):await())
    must(pane:send_keys({ "Enter" }):await())
    local wait = pane:wait_for_text("lua input ready", { timeout = 5000 })
    local found = must(wait:await())
    local matched = found.text:find("lua input ready", 1, true)
    assert(matched, "the command did not print its line")
    print("lua input ready")

    must(owned:stop():await())
    return true
end))
