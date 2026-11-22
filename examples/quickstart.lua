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
    local created = must(server
        :new_session({
            name = "quickstart",
            window_name = "main",
            argv = { "/bin/sh" },
        })
        :await())
    local window_opts = { name = "logs", argv = { "/bin/cat" } }
    local logs = must(created.session:new_window(window_opts):await())
    local split_opts = {
        direction = "right",
        percent = 40,
        argv = { "/bin/cat" },
    }
    local split = must(logs.pane:split(split_opts):await())

    -- The shell echoes what is typed, so print the needle from two pieces.
    must(created.pane:send_text("printf '%s%s\\n' 'libtmux ' 'ready'"):await())
    must(created.pane:send_keys({ "Enter" }):await())
    local wait = created.pane:wait_for_text("libtmux ready", { timeout = 5000 })
    local found = must(wait:await())
    local matched = found.text:find("libtmux ready", 1, true)
    assert(matched, "pane output was not read")
    local session_id = created.session:reference().id
    local window_id = logs.window:reference().id
    print(session_id, window_id, split.pane:reference().id)

    must(created.session:kill():await())
    -- docs:end main
    must(owned:stop():await())
    return true
end))

assert(result)
