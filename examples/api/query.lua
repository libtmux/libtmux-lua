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
    local session_options = {
        name = "demo",
        window_name = "main",
        argv = { "/bin/cat" },
    }
    must(server:new_session(session_options):await())
    must(server:new_session({ name = "worker", argv = { "/bin/cat" } }):await())
    local query_options = {
        kind = "session",
        where = { name = "demo" },
        snapshot = { strict = true },
    }
    local result = must(server:query(query_options):await())
    assert(result.complete, "query observed a topology change")
    assert(
        #result.rows == 1 and result.rows[1].name == "demo",
        "query selected the wrong session"
    )
    print("matched: " .. result.rows[1].name)

    must(server:close():await())
    return true
end))
