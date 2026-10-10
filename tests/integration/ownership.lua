local adapter = require("libtmux.runtime.luv")
local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end
local value, err = adapter.run(function(runtime)
    local server = must(runtime:connect():await())
    local owner = must(server:owned_session({ name = "owned", argv = { "/bin/cat" } }):await())
    local session = owner.value
    assert(must(session:snapshot():await()).name == "owned")
    must(session:rename("renamed-owned"):await())
    local found = must(server:find_or_create_session("renamed-owned"):await())
    assert(not found.created and found.owner == nil)
    local window = must(session:owned_window({ name = "window", argv = { "/bin/cat" } }):await())
    local window_snapshot = must(window.value:snapshot():await())
    local pane
    -- Obtain the pane from the same snapshot used to bind it.
    local snapshot = must(server:snapshot():await())
    for _, record in ipairs(snapshot.panes) do
        if record.window_id == window_snapshot.id then
            pane = must(server:handle(snapshot, record))
        end
    end
    local split = must(pane:owned_pane({ argv = { "/bin/cat" } }):await())
    must(split:close():await())
    must(split:close():await())
    local first = must(window.value:find_or_create_pane("work", { argv = { "/bin/cat" } }):await())
    assert(first.created and first.owner)
    local second = must(window.value:find_or_create_pane("work"):await())
    assert(not second.created and not second.owner)
    must(first.owner:close():await())
    must(window:close():await())
    must(owner:close():await())
    assert(owner.closed)
    print("ownership smoke PASS")
    return true
end)
assert(value, tostring(err))
