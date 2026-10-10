local adapter = require("libtmux.runtime.luv")
local entities = require("libtmux._internal.entity")
local codec = require("libtmux._internal.codec")
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
local value, err = adapter.run(function(runtime)
    local server = must(runtime:connect():await())
    local wrap, spawn = entities.from_reference, uv.spawn
    local marker = { code = "wrap_failure", message = "receipt retained through wrapping failure" }
    -- Deliberate fault injection; restored before recovery.
    ---@diagnostic disable-next-line: duplicate-set-field
    entities.from_reference = function()
        return nil, marker
    end
    -- Deliberate fault injection; restored before recovery.
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(binary, options, callback)
        for _, argument in ipairs(options.args) do
            if argument:find("kill-session", 1, true) then
                return nil, "rollback transport fault"
            end
        end
        return spawn(binary, options, callback)
    end
    local accepted, failure =
        server:owned_session({ name = "recoverable", argv = { "/bin/cat" } }):await()
    entities.from_reference, uv.spawn = wrap, spawn
    check(not accepted and failure.code == "cleanup_failed")
    check(failure.cause == marker and marker.owner and not marker.owner.closed)
    check(failure.errors[1].code == "rollback_failed" and failure.errors[1].owner == marker.owner)
    must(marker.owner:close():await())
    check(marker.owner.closed, "complete receipt must retain a retryable recovery owner")

    local decode = codec.decode
    -- Simulate a truncated native receipt only after the creation command ran.
    ---@diagnostic disable-next-line: duplicate-set-field
    codec.decode = function(text, count, options)
        local rows, cause = decode(text, count, options)
        if count == 7 and rows and rows[1] and rows[1][4] ~= "$0" then
            return nil, { code = "truncated", message = "injected lost creation receipt" }
        end
        return rows, cause
    end
    accepted, failure =
        server:owned_session({ name = "unknown-receipt", argv = { "/bin/cat" } }):await()
    codec.decode = decode
    check(not accepted and failure.code == "cleanup_failed")
    check(failure.cause.code == "invalid_receipt" and failure.errors[1].code == "creation_unknown")
    local listing = must(server:command({ "list-sessions", "-F", "#{session_name}" }):await())
    check(
        listing.stdout:find("unknown-receipt", 1, true),
        "unknown receipt must not guess a target"
    )
    print("receipt failure checks PASS " .. checks)
    return true
end)
assert(checks == 7 and not value and err and err.code == "cleanup_failed", tostring(err))
assert(#err.errors == 2, "both deferred rollback diagnostics must survive")
