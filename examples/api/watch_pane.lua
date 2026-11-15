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
    local created = must(
        owned.server
            :new_session({ name = "demo", window_name = "main", argv = { "/bin/cat" } })
            :await()
    )
    -- Observation holds one control-mode client open; it needs tmux 3.7 or newer.
    local observation = must(owned.server:observe(created.session):await())
    local watch = must(observation:watch_pane(created.pane):await())

    must(created.pane:send_text("watched"):await())
    local output = ""
    while not output:find("watched", 1, true) do
        output = output .. must(watch:next({ timeout = 5000 }):await()).data
    end
    print("output: watched")

    must(observation:close():await())
    must(owned:stop():await())
    return true
end))
