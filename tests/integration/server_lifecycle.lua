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
    local first = must(runtime:find_or_create_server({ socket_path = root .. "/fresh" }):await())
    assert(first.created and first.owner)
    local second = must(runtime:find_or_create_server({ socket_path = root .. "/fresh" }):await())
    assert(not second.created and second.owner == nil)
    local found =
        must(first.value:find_or_create_session("session", { argv = { "/bin/cat" } }):await())
    assert(found.created)
    local discovery =
        must(runtime:discover_servers({ roots = { root }, paths = { root .. "/missing" } }):await())
    assert(#discovery.servers == 2, "expected fixture and newly created server")
    assert(#discovery.diagnostics >= 1)
    must(found.owner:close():await())
    must(first.owner:close():await())
    local stale = assert(uv.fs_lstat(root .. "/fresh"))
    assert(stale.type == "socket", "the published alias remains after daemon exit")
    local absent, failure =
        runtime:find_or_create_server({ socket_path = root .. "/fresh" }):await()
    assert(not absent and failure, "a stale publication must not start a replacement")
    local retained = assert(uv.fs_lstat(root .. "/fresh"))
    assert(retained.dev == stale.dev and retained.ino == stale.ino)
    absent, failure = runtime:owned_server({ socket_path = root .. "/fresh" }):await()
    assert(not absent and failure and failure.code == "already_exists")
    -- This fixture owns the directory namespace and its old daemon has exited.
    -- It can retire its stale publication before a new server uses that path.
    must(uv.fs_unlink(root .. "/fresh"))
    local restarted =
        must(runtime:find_or_create_server({ socket_path = root .. "/fresh" }):await())
    assert(restarted.created and restarted.owner)
    must(restarted.owner:close():await())
    local named = must(runtime
        :owned_server({
            socket_name = "fresh-named",
            client_env = { LIBTMUX_SOCKET_PATH = false, TMUX_TMPDIR = root },
        })
        :await())
    must(named:close():await())
    print("server lifecycle smoke PASS")
    return true
end)
if not value and type(err) == "table" then
    io.stderr:write("code: ", tostring(err.code), "\n")
    if err.cause then
        io.stderr:write("cause: ", tostring(err.cause), "\n")
    end
    for _, failure in ipairs(err.errors or {}) do
        io.stderr:write("cleanup: ", tostring(failure), "\n")
    end
end
assert(value, tostring(err))
