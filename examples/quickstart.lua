local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

local result = must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local server = owned.server

    -- docs:begin main
    local created = must(
        server
            :new_session({ name = "quickstart", window_name = "main", argv = { "/bin/sh" } })
            :await()
    )
    local logs = must(created.session:new_window({ name = "logs", argv = { "/bin/cat" } }):await())
    local split =
        must(logs.pane:split({ direction = "right", percent = 40, argv = { "/bin/cat" } }):await())

    -- The shell echoes what is typed, so print the needle from two pieces.
    must(created.pane:send_text("printf '%s%s\\n' 'libtmux ' 'ready'"):await())
    must(created.pane:send_keys({ "Enter" }):await())
    local found = must(created.pane:wait_for_text("libtmux ready", { timeout = 5000 }):await())
    assert(found.text:find("libtmux ready", 1, true), "pane output was not read")
    print(created.session:reference().id, logs.window:reference().id, split.pane:reference().id)

    must(created.session:kill():await())
    -- docs:end main
    must(owned:stop():await())
    return true
end))

assert(result)
