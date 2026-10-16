local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

local result, failure = adapter.run(function(runtime)
    local server = must(runtime:connect():await())
    local created
    must(runtime:defer(function()
        if created then
            must(created.session:kill():await())
        end
    end))
    created = must(server:new_session({ name = "ordinary-example", argv = { "/bin/cat" } }):await())
    local snapshot = must(created.session:snapshot():await())
    assert(snapshot.name == "ordinary-example", "created session has the wrong name")
    print("session: " .. snapshot.name)
    return true
end)
assert(result, tostring(failure))
