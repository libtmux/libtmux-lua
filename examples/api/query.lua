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
    local server = owned.server
    must(server
        :new_session({
            name = "demo",
            window_name = "main",
            argv = { "/bin/cat" },
        })
        :await())
    must(server:new_session({ name = "worker", argv = { "/bin/cat" } }):await())
    local result = must(server
        :query({
            kind = "session",
            where = { name = "demo" },
            snapshot = { strict = true },
        })
        :await())
    assert(result.complete, "query observed a topology change")
    assert(#result.rows == 1 and result.rows[1].name == "demo", "query selected the wrong session")
    print("matched: " .. result.rows[1].name)

    must(owned:stop():await())
    return true
end))
