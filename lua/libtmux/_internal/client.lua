local errors = require("libtmux._internal.error")
local execution = require("libtmux._internal.execution")
local identity = require("libtmux._internal.identity")
local metadata = require("libtmux._internal.metadata")
local process = require("libtmux._internal.process")
local M = {}
local MAX_BYTES = 1048576
local process_fields = {
    timeout = true,
    deadline = true,
    max_output_bytes = true,
    drain_timeout = true,
    kill_timeout = true,
}

local function failure(kind, code, message, effect, cause, partial)
    return errors.new(code, message, {
        operation = "client." .. kind,
        effect = effect or "not_sent",
        cause = cause,
        partial = partial,
    })
end

local function current(state, kind, expected)
    if state.closed then
        return nil, failure(kind, "closed", "server handle is closed")
    end
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    if expected and not rawequal(generation, expected) then
        return nil, failure(kind, "stale_generation", "server generation changed")
    end
    return generation
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function bounded(value, nonempty)
    return type(value) == "string"
        and (not nonempty or #value > 0)
        and #value <= 4096
        and not value:find("\000", 1, true)
end

local function prepare(state, kind, selector, destination, options, inspect)
    local function invalid(code, message)
        error(failure(kind, code, message), 0)
    end
    if kind ~= "detach" and kind ~= "switch" then
        invalid("invalid_operation", "unknown client operation")
    end
    if not plain(selector) or not bounded(selector.name, true) or not bounded(selector.tty) then
        invalid("invalid_target", "client selector requires a bounded name and TTY")
    end
    for key in next, selector do
        if key ~= "name" and key ~= "tty" then
            invalid("invalid_target", "unknown client selector field")
        end
    end
    if options ~= nil and not plain(options) then
        invalid("invalid_options", "client options must be a plain record")
    end
    options = options or {}
    for key in next, options do
        if key ~= "process" and not (kind == "switch" and key == "update_environment") then
            invalid("invalid_options", "unknown client option")
        end
    end
    if options.update_environment ~= nil and type(options.update_environment) ~= "boolean" then
        invalid("invalid_options", "update_environment must be boolean")
    end
    local generation, err = current(state, kind)
    if not generation then
        error(err, 0)
    end
    local target = selector.name
    -- Native lookup strips one trailing colon, even when it belongs to the name.
    if target:sub(-1) == ":" then
        target = target .. ":"
    end
    local argv
    if kind == "switch" then
        local ref
        ref, err = inspect(state, destination, "session")
        if not ref then
            error(err, 0)
        end
        argv = { "switch-client" }
        if not options.update_environment then
            argv[#argv + 1] = "-E"
        end
        argv[#argv + 1], argv[#argv + 2] = "-c", target
        argv[#argv + 1], argv[#argv + 2] = "-t", ref.id
    else
        if destination ~= nil then
            invalid("invalid_target", "detach has no destination")
        end
        argv = { "detach-client", "-t", target }
    end
    local projection
    projection, err = metadata.projection("client", state.version, { "name", "tty" })
    if not projection then
        error(err, 0)
    end
    local configured = { max_output_bytes = MAX_BYTES }
    if options.process ~= nil then
        if not plain(options.process) then
            invalid("invalid_options", "client process options must be a plain record")
        end
        for key, value in next, options.process do
            if not process_fields[key] then
                invalid("invalid_options", "unsupported client process option")
            end
            configured[key] = value
        end
        if
            type(configured.max_output_bytes) ~= "number"
            or configured.max_output_bytes > MAX_BYTES
        then
            invalid("invalid_options", "client output limit must not exceed one MiB")
        end
    end
    local commands, copied, cost = execution.prepare(state.runtime, {
        { "list-clients", "-F", assert(metadata.format(projection)) },
        argv,
    }, configured, false)
    if not commands then
        error(copied, 0)
    end
    return {
        generation = generation,
        commands = commands,
        options = copied,
        bytes = cost + #selector.name + #selector.tty,
        name = selector.name,
        tty = selector.tty,
        projection = projection,
    }
end

local function member(plan, rows, kind)
    local exact, matches = 0, 0
    for _, row in ipairs(rows) do
        if row.name == plan.name and row.tty == plan.tty then
            exact = exact + 1
        end
        if
            row.name == plan.name
            or row.tty == plan.name
            or (row.tty:sub(1, 5) == "/dev/" and row.tty:sub(6) == plan.name)
        then
            matches = matches + 1
        end
    end
    if matches > 1 then
        return nil, failure(kind, "ambiguous_target", "client name matches multiple attachments")
    elseif exact ~= 1 then
        return nil, failure(kind, "missing_target", "client name and TTY are not attached")
    end
    return true
end

function M.run(state, kind, selector, destination, options, inspect)
    local ok, prepared = pcall(prepare, state, kind, selector, destination, options, inspect)
    local plan = ok and prepared or nil
    local request = state.runtime:_operation(function(_, active)
        if not plan then
            return nil, prepared
        end
        local generation, err = current(state, kind, plan.generation)
        if not generation then
            return nil, err
        end
        local listing, cause = state.bound:execute(plan.commands[1], plan.options):await()
        listing, cause = process.retain_output(active, listing, cause, "client." .. kind)
        if not listing then
            return nil, failure(kind, cause.code, cause.message, "not_sent", cause)
        end
        local rows
        rows, cause = metadata.decode(
            listing.stdout,
            plan.projection,
            { max_rows = 1024, max_bytes = MAX_BYTES }
        )
        if not rows then
            assert(cause)
            return nil, failure(kind, cause.code, cause.message, "not_sent", cause)
        end
        local accepted
        accepted, cause = active:_retain(#listing.stdout + #rows * 32)
        if not accepted then
            return nil, failure(kind, cause.code, cause.message, "not_sent", cause)
        end
        accepted, cause = member(plan, rows, kind)
        if not accepted then
            return nil, cause
        end
        generation, err = current(state, kind, plan.generation)
        if not generation then
            return nil, err
        end
        active:_set_effect("unknown")
        local result
        result, cause = state.bound:execute(plan.commands[2], plan.options):await()
        result, cause = process.retain_output(active, result, cause, "client." .. kind)
        if not result then
            return nil, cause
        end
        active:_set_effect("completed")
        generation, err = current(state, kind, plan.generation)
        if not generation then
            assert(err)
            return nil, failure(kind, err.code, err.message, "completed", err, result)
        end
        return true
    end, { operation = "client." .. kind, effect = "not_sent" })
    if plan and not request:is_settled() then
        local accepted, cause = request:_retain(plan.bytes)
        if not accepted then
            request:cancel(
                failure(kind, "queue_full", "client request exceeds byte capacity", nil, cause)
            )
        end
    end
    return request
end

function M.attach(state, owned)
    return state.runtime:_operation(function()
        local generation, err = current(state, "attach")
        if not generation then
            return nil, err
        end
        local ref
        ref, err = identity.inspect(generation, owned)
        if not ref then
            return nil, err
        end
        if ref.kind ~= "session" then
            return nil,
                failure("attach", "invalid_target", "interactive attachment requires a Session")
        end
        return nil,
            failure(
                "attach",
                "unsupported_tty",
                "this adapter does not own an interactive terminal"
            )
    end, { operation = "client.attach", effect = "not_sent" })
end

---@class libtmux.ClientSelector
---@field name string Exact observed client name; selects its current attachment.
---@field tty string Exact observed TTY, including empty for a client without a terminal.

---@class libtmux.ClientOptions
---@field process? libtmux.CreationProcessOptions Limits apply to each subprocess; one MiB maximum.

---@class libtmux.SwitchClientOptions: libtmux.ClientOptions
---@field update_environment? boolean Apply the client's update-environment values; default false.

return M
