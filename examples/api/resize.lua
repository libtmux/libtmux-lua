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
    local session = { name = "demo", argv = { "/bin/cat" } }
    local created = must(owned.server:new_session(session):await())
    local split_opts = { direction = "right", argv = { "/bin/cat" } }
    local split = must(created.pane:split(split_opts):await())

    must(created.window:resize({ width = 100, height = 30 }):await())
    must(split.pane:resize({ width = 30 }):await())

    -- A resize can clamp to the layout, so read the sizes tmux settled on.
    local window = must(created.window:snapshot():await())
    local pane = must(split.pane:snapshot():await())
    local sized = window.width == 100 and window.height == 30
    assert(sized, "the window kept its old size")
    assert(pane.width == 30, "the pane kept its old width")
    local template = "window %dx%d, pane %d wide"
    print(template:format(window.width, window.height, pane.width))

    must(owned:stop():await())
    return true
end))
