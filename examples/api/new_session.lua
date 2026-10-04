local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

local binary =
    assert(os.getenv("TMUX_BIN"), "set TMUX_BIN to an absolute tmux executable")
local socket =
    assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to the private socket")

must(adapter.run(function(runtime)
    local server =
        must(runtime:connect({ binary = binary, socket_path = socket }):await())
    local created = must(server
        :new_session({
            name = "demo",
            window_name = "main",
            argv = { "/bin/cat" },
        })
        :await())
    assert(
        created.session and created.window and created.pane,
        "creation handles are missing"
    )
    local snapshot = must(created.session:snapshot():await())
    assert(snapshot.name == "demo", "created session has the wrong name")
    print("session: " .. snapshot.name)

    must(server:close():await())
    return true
end))
