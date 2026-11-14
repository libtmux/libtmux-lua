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
    local created = must(server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())
    local split = must(created.pane:split({ direction = "right", argv = { "/bin/cat" } }):await())

    must(created.window:resize({ width = 100, height = 30 }):await())
    must(split.pane:resize({ width = 30 }):await())

    -- A resize can clamp to the layout, so read the sizes tmux settled on.
    local window = must(created.window:snapshot():await())
    local pane = must(split.pane:snapshot():await())
    assert(window.width == 100 and window.height == 30, "the window kept its old size")
    assert(pane.width == 30, "the pane kept its old width")
    print(("window %dx%d, pane %d wide"):format(window.width, window.height, pane.width))

    must(server:close():await())
    return true
end))
