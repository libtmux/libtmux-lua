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
local function contains(options, text)
    for _, value in ipairs(options.args) do
        if value == text then
            return true
        end
    end
    return false
end
local value, err = adapter.run(function(runtime)
    local root = assert(os.getenv("LIBTMUX_TEST_ROOT"))
    local spawn, denied = uv.spawn, 0
    -- A daemon socket can exist before it accepts its first no-start client.
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(binary, options, callback)
        if not contains(options, "-D") and contains(options, "#{pid}") and denied == 0 then
            denied = denied + 1
            return nil, "injected not-yet-ready listener"
        end
        return spawn(binary, options, callback)
    end
    local owner = must(runtime:owned_server({ socket_path = root .. "/readiness" }):await())
    uv.spawn = spawn
    assert(denied == 1 and owner:receipt().pid)
    must(owner:close():await())

    -- Spawn failure must not publish a socket or strand its allocated directory.
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(binary, options, callback)
        if contains(options, "-D") then
            return nil, "injected foreground spawn failure"
        end
        return spawn(binary, options, callback)
    end
    local absent, failure = runtime:owned_server({ socket_path = root .. "/spawn-fails" }):await()
    uv.spawn = spawn
    assert(not absent and failure and failure.code == "spawn_failed")
    assert(uv.fs_lstat(root .. "/spawn-fails") == nil)

    local pending, scheduled
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(binary, options, callback)
        local child, pid = spawn(binary, options, callback)
        if child and contains(options, "-D") and not scheduled then
            scheduled = true
            local timer = uv.new_timer()
            timer:start(0, 0, function()
                timer:close()
                pending:cancel("cancel startup after accepting native child")
            end)
        end
        return child, pid
    end
    pending = runtime:owned_server({ socket_path = root .. "/cancel-start" })
    absent, failure = pending:await()
    uv.spawn = spawn
    assert(not absent and failure and failure.code == "cancelled")
    assert(uv.fs_lstat(root .. "/cancel-start") == nil)
    local directory = must(uv.fs_scandir(root))
    while true do
        local name = uv.fs_scandir_next(directory)
        if not name then
            break
        end
        assert(
            not name:find("libtmux-lua-start-", 1, true),
            "startup cleanup left an owned directory"
        )
    end
    print("startup readiness, failed spawn and cancelled startup PASS")
    return true
end)
if err then
    local function describe(failure)
        io.stderr:write(tostring(failure.code), ": ", tostring(failure), "\n")
        if type(failure.cause) == "table" then
            describe(failure.cause)
        end
        for _, child in ipairs(failure.errors or {}) do
            describe(child)
        end
    end
    describe(err)
end
assert(value, tostring(err))
