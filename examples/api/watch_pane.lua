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
    local created = must(
        server:new_session({ name = "demo", window_name = "main", argv = { "/bin/cat" } }):await()
    )
    -- Observation holds one control-mode client open; it needs tmux 3.7 or newer.
    local observation = must(server:observe(created.session):await())
    local watch = must(observation:watch_pane(created.pane):await())

    must(created.pane:send_text("watched"):await())
    local output = ""
    while not output:find("watched", 1, true) do
        output = output .. must(watch:next({ timeout = 5000 }):await()).data
    end
    print("output: watched")

    must(observation:close():await())
    must(server:close():await())
    return true
end))
