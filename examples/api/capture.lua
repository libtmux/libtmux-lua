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
    must(pane:send_text("printf '%s%s\\n' 'lua capture ' 'ready'"):await())
    must(pane:send_keys({ "Enter" }):await())
    must(pane:wait_for_text("lua capture ready", { timeout = 5000 }):await())
    local capture = must(pane:capture({ history_lines = 20 }):await())
    local found = false
    for line in must(capture:text()):gmatch("[^\r\n]+") do
        if line == "lua capture ready" then
            found = true
        end
    end
    assert(found, "completed command did not print the expected line")
    print("lua capture ready")

    must(owned:stop():await())
    return true
end))
