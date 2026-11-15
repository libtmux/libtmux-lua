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
    local created = must(owned.server
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

    must(owned:stop():await())
    return true
end))
