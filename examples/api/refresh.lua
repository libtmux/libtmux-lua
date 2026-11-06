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
    local created = must(server
        :new_session({
            name = "demo",
            window_name = "editor",
            argv = { "/bin/cat" },
        })
        :await())
    local window = created.window
    local held = must(window:snapshot():await())
    must(window:rename("build"):await())
    local fresh = must(window:snapshot():await())
    assert(held.name == "editor" and fresh.name == "build", "refresh did not read the rename")
    print(held.name .. " " .. fresh.name)

    must(server:close():await())
    return true
end))
