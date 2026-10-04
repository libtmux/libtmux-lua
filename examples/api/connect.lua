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
    local snapshot = must(server:snapshot({ strict = true }):await())
    assert(
        #snapshot.sessions:where({ name = "bootstrap" }) == 1,
        "bootstrap session is missing"
    )
    print("connected")

    must(server:close():await())
    return true
end))
