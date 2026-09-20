local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

local binary = assert(os.getenv("TMUX_BIN"), "set TMUX_BIN to an absolute tmux executable")
local socket = assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to an explicit socket")

local result = must(adapter.run(function(runtime)
    local server = must(runtime:connect({ binary = binary, socket_path = socket }):await())

    -- docs:begin main
    local created = must(
        server
            :new_session({ name = "quickstart", window_name = "main", argv = { "/bin/sh" } })
            :await()
    )
    local logs = must(created.session:new_window({ name = "logs", argv = { "/bin/cat" } }):await())
    local split =
        must(logs.pane:split({ direction = "right", percent = 40, argv = { "/bin/cat" } }):await())

    local marker = "libtmux-lua-quickstart"
    must(created.pane:send_text("printf 'libtmux ready\\n'; tmux wait-for -S " .. marker):await())
    must(created.pane:send_keys({ "Enter" }):await())
    must(server:command({ "wait-for", marker }):await())

    local capture = must(created.pane:capture({ history_lines = 20 }):await())
    assert(must(capture:text()):find("libtmux ready", 1, true), "pane output was not captured")
    print(created.session:reference().id, logs.window:reference().id, split.pane:reference().id)

    must(created.session:kill():await())
    -- docs:end main
    must(server:close():await())
    return true
end))

assert(result)
