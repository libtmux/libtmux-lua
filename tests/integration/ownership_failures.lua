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
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local function has(spec, fragment)
    for _, argument in ipairs(spec.args) do
        if argument:find(fragment, 1, true) then
            return true
        end
    end
    return false
end

local value, err = adapter.run(function(runtime)
    local server = must(runtime:connect():await())
    local body = { code = "body_failure", message = "body marker" }
    local scoped, scope_error = server
        :with_session({ name = "body-failure", argv = { "/bin/cat" } }, function()
            error(body, 0)
        end)
        :await()
    check(scoped == nil and scope_error == body, "body identity must survive successful cleanup")
    local listing = must(server:command({ "list-sessions", "-F", "#{session_name}" }):await())
    check(not listing.stdout:find("body-failure", 1, true))

    local spawn = uv.spawn
    local owner = must(server:owned_session({ name = "retry", argv = { "/bin/cat" } }):await())
    -- Deliberate fault injection; the original implementation is restored below.
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(binary, spec, callback)
        if has(spec, "kill-session") then
            return nil, "injected destruction failure"
        end
        return spawn(binary, spec, callback)
    end
    local cleaned, cleanup_error = owner:close():await()
    uv.spawn = spawn
    check(
        not cleaned and cleanup_error and not owner.closed and owner.cleanup_error == cleanup_error
    )
    must(owner:close():await())
    check(owner.closed)

    local survivor
    -- Deliberate fault injection; the original implementation is restored below.
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(binary, spec, callback)
        if has(spec, "kill-session") then
            return nil, "injected cleanup failure"
        end
        return spawn(binary, spec, callback)
    end
    local combined, combined_error = server
        :with_session({ name = "both-fail", argv = { "/bin/cat" } }, function(_, accepted)
            survivor = accepted
            error(body, 0)
        end)
        :await()
    uv.spawn = spawn
    check(combined == nil and combined_error.code == "cleanup_failed")
    check(combined_error.cause == body and #combined_error.errors == 1)
    must(survivor:close():await())

    local rejected = false
    -- Deliberate fault injection; the original implementation is restored below.
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(binary, spec, callback)
        if has(spec, "new-session") and has(spec, "rollback") then
            return spawn(binary, spec, function(_, signal)
                rejected = true
                callback(1, signal)
            end)
        end
        return spawn(binary, spec, callback)
    end
    local created, creation_error =
        server:owned_session({ name = "rollback", argv = { "/bin/cat" } }):await()
    uv.spawn = spawn
    check(not created and creation_error and rejected, "creation transport failure must be visible")
    listing = must(server:command({ "list-sessions", "-F", "#{session_name}" }):await())
    check(not listing.stdout:find("rollback", 1, true), "complete receipt must roll back creation")

    local cancelling
    cancelling = server:with_session({ name = "cancelled-scope", argv = { "/bin/cat" } }, function()
        local timer = uv.new_timer()
        timer:start(0, 0, function()
            timer:close()
            cancelling:cancel("cancel marker")
        end)
        return server:command({ "wait-for", "never-released" }):await()
    end)
    local cancelled, cancel_error = cancelling:await()
    check(cancelled == nil and cancel_error.code == "cancelled")
    listing = must(server:command({ "list-sessions", "-F", "#{session_name}" }):await())
    check(not listing.stdout:find("cancelled-scope", 1, true))

    owner = must(server:owned_session({ name = "token-change", argv = { "/bin/cat" } }):await())
    local receipt = owner:receipt()
    must(
        server
            :command({ "set-option", "-s", "@libtmux_owner_generation", string.rep("b", 32) })
            :await()
    )
    cleaned, cleanup_error = owner:close():await()
    check(not cleaned and cleanup_error.code == "stale_generation")
    check(must(owner.value:snapshot():await()).name == "token-change")
    must(server:command({ "set-option", "-s", "@libtmux_owner_generation", receipt.token }):await())
    must(owner:close():await())

    must(server:command({ "set-option", "-s", "@libtmux_owner_generation", "bad" }):await())
    local malformed, malformed_error =
        server:owned_session({ name = "malformed-token", argv = { "/bin/cat" } }):await()
    check(not malformed and malformed_error.code == "invalid_receipt")
    must(server:command({ "set-option", "-s", "@libtmux_owner_generation", receipt.token }):await())
    listing = must(server:command({ "list-sessions", "-F", "#{session_name}" }):await())
    check(
        not listing.stdout:find("malformed-token", 1, true),
        "malformed token must fail before creation"
    )

    local borrowed = must(runtime:connect():await())
    local retained =
        must(borrowed:owned_session({ name = "closed-client", argv = { "/bin/cat" } }):await())
    must(borrowed:close():await())
    must(retained:close():await())
    check(retained.closed, "owner pin must outlive borrowed client close")

    local first_request = server:find_or_create_session("concurrent", { argv = { "/bin/cat" } })
    local second_request = server:find_or_create_session("concurrent", { argv = { "/bin/cat" } })
    local first, second = must(first_request:await()), must(second_request:await())
    check(first.created and not second.created)
    check(first.value:reference().id == second.value:reference().id)
    must(first.owner:close():await())
    print("ownership failure checks PASS " .. checks)
    return true
end)
if not value and type(err) == "table" and checks ~= 17 then
    io.stderr:write("code: ", tostring(err.code), "\n")
    if err.cause then
        io.stderr:write("cause: ", tostring(err.cause), "\n")
    end
    for _, failure in ipairs(err.errors or {}) do
        io.stderr:write("cleanup: ", tostring(failure), "\n")
    end
end
assert(checks == 17 and not value and err and err.code == "cleanup_failed", tostring(err))
assert(#err.errors == 1, "the runtime retains the handled deferred-cleanup diagnostic")
