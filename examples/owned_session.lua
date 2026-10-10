local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end

local result, err = adapter.run(function(runtime)
    local server = must(runtime:connect():await())
    return server
        :with_session({ name = "owned-example", argv = { "/bin/cat" } }, function(session)
            local snapshot = must(session:snapshot():await())
            print("session: " .. snapshot.name)
            return true
        end)
        :await()
end)
assert(result, tostring(err))
