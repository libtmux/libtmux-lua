local adapter = require("libtmux.runtime.luv")
-- luv is the native host module, distinct from libtmux.runtime.luv.
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end
local value, err = adapter.run(function(runtime)
    local root = assert(os.getenv("LIBTMUX_TEST_ROOT"))
    local socket = os.getenv("LIBTMUX_SOCKET_PATH")
        or root .. "/tmux-" .. uv.getuid() .. "/" .. assert(os.getenv("LIBTMUX_SOCKET_NAME"))
    local binary = assert(os.getenv("LIBTMUX_TEST_BINARY"))
    local spawn, expected, observed = uv.spawn, "", 0
    -- The additive ConnectOptions.env supplies each native child's environment.
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(program, options, callback)
        assert(options.env and table.concat(options.env, "\n") == expected)
        observed = observed + 1
        return spawn(program, options, callback)
    end
    local empty = must(runtime:connect({ binary = binary, socket_path = socket, env = {} }):await())
    assert(
        must(empty:command({ "display-message", "-p", "empty env" }):await()).stdout
            == "empty env\n"
    )
    must(empty:close():await())
    local options = {
        binary = binary,
        socket_path = socket,
        env = { "COMPAT=before", "TMUX=ignored", "TMUX_PANE=%99", "KEEP=value" },
    }
    expected = "COMPAT=before\nKEEP=value"
    local request = runtime:connect(options)
    options.env[1] = "COMPAT=after"
    local full = must(request:await())
    assert(
        must(full:command({ "display-message", "-p", "full env" }):await()).stdout == "full env\n"
    )
    must(full:close():await())
    expected = ""
    local owned = must(
        runtime
            :owned_server({ binary = binary, socket_path = root .. "/legacy-start", env = {} })
            :await()
    )
    must(owned:close():await())
    uv.spawn = spawn
    assert(observed > 0 and uv.os_getenv("COMPAT") == nil)
    print("ConnectOptions.env empty/full environment capture and startup PASS")
    return true
end)
assert(value, tostring(err))
