local adapter = require("libtmux.runtime.luv")
-- luv is the native host module, distinct from libtmux.runtime.luv.
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
local entities = require("libtmux._internal.entity")
local codec = require("libtmux._internal.codec")
local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local value, err = adapter.run(function(runtime)
    local root = assert(os.getenv("LIBTMUX_TEST_ROOT"))
    local server = must(runtime:connect():await())
    local wrap = entities.from_reference
    local marker = { code = "wrap_failure", message = "injected wrapping failure" }
    -- Deliberate fault injection; the original implementation is restored below.
    ---@diagnostic disable-next-line: duplicate-set-field
    entities.from_reference = function()
        return nil, marker
    end
    local missing, wrap_error =
        server:owned_session({ name = "wrapping", argv = { "/bin/cat" } }):await()
    entities.from_reference = wrap
    check(not missing and wrap_error == marker)
    check(marker.owner and marker.owner.closed, "complete receipt must survive wrapping failure")
    local listing = must(server:command({ "list-sessions", "-F", "#{session_name}" }):await())
    check(not listing.stdout:find("wrapping", 1, true), "wrapping failure must roll back")

    local decode, pending, cancelled = codec.decode, nil, false
    -- Deliberate fault injection; the original implementation is restored below.
    ---@diagnostic disable-next-line: duplicate-set-field
    codec.decode = function(text, count, options)
        local rows, cause = decode(text, count, options)
        if count == 7 and rows and rows[1] and rows[1][4] ~= "" and pending and not cancelled then
            -- The pre-creation server receipt names the existing fixture. Cancel
            -- only the receipt emitted by the newly created session.
            if rows[1][4] ~= "$0" then
                cancelled = true
                pending:cancel("receipt delivered before cancellation")
            end
        end
        return rows, cause
    end
    pending = server:owned_session({ name = "receipt-cancel", argv = { "/bin/cat" } })
    local accepted, cancellation = pending:await()
    codec.decode = decode
    check(not accepted and cancellation.code == "cancelled" and cancelled)
    listing = must(server:command({ "list-sessions", "-F", "#{session_name}" }):await())
    check(
        not listing.stdout:find("receipt-cancel", 1, true),
        "accepted cancelled receipt must roll back"
    )

    local options = { name = "copied-scope", argv = { "/bin/cat" } }
    local scoped = server:with_session(options, function(session)
        local snapshot = must(session:snapshot():await())
        check(snapshot.name == "copied-scope")
        return true
    end)
    options.name, options.argv[1] = "changed-after-call", "/not-a-command"
    must(scoped:await())
    options = { socket_path = root .. "/captured-server" }
    local startup = runtime:with_server(options, function(owned)
        check(uv.fs_lstat(root .. "/captured-server").type == "socket")
        return owned:command({ "display-message", "-p", "captured" }):await()
    end)
    options.socket_path = root .. "/changed-after-call"
    must(startup:await())
    check(uv.fs_lstat(root .. "/captured-server").type == "socket")
    check(uv.fs_lstat(root .. "/changed-after-call") == nil)

    local first_request = runtime:find_or_create_server({ socket_path = root .. "/race" })
    local second_request = runtime:find_or_create_server({ socket_path = root .. "/race" })
    local first, second = must(first_request:await()), must(second_request:await())
    check(first.created ~= second.created, "atomic publication must choose exactly one owner")
    local created, reused = first.created and first or second, first.created and second or first
    check(created.owner and reused.owner == nil)
    must(created.owner:close():await())

    local released = must(runtime:owned_server({ socket_path = root .. "/adopt-server" }):await())
    local borrowed = must(released:release())
    local adopted = must(borrowed:adopt():await())
    must(adopted:close():await())
    check(adopted.closed, "a borrowed daemon can be explicitly adopted")
    -- A released startup directory is now the caller's responsibility. This
    -- harness owns the original root and observes exits before removing it.

    local unowned =
        must(server:new_session({ name = "borrowed-survives", argv = { "/bin/cat" } }):await())
    local operation = server:with_session(
        { name = "lookup-scope", argv = { "/bin/cat" } },
        function()
            local result = must(server:find_or_create_session("borrowed-survives"):await())
            check(not result.created and not result.owner)
            return true
        end
    )
    must(operation:await())
    check(must(unowned.session:snapshot():await()).name == "borrowed-survives")
    must(must(unowned.session:adopt():await()):close():await())
    print("acquisition checks PASS " .. checks)
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
