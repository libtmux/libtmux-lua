local codec = require("libtmux._internal.environment_codec")
local errors = require("libtmux._internal.error")
local execution = require("libtmux._internal.execution")
local process = require("libtmux._internal.process")
local scope = require("libtmux._internal.scope")
local M = {}
local MAX_BYTES, MAX_ROWS, VERIFY_GROUP = 1048576, 4096, 128
local kinds = { get = true, list = true, set = true, unset = true, remove = true }
local process_fields = {
    timeout = true,
    deadline = true,
    max_output_bytes = true,
    drain_timeout = true,
    kill_timeout = true,
}

local function failure(kind, code, message, effect, cause, target)
    return errors.new(code, message, {
        operation = "environment." .. kind,
        effect = effect or "not_sent",
        cause = cause,
        target = target,
    })
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function command(resolved, kind, name, value, hidden)
    local argv = { (kind == "get" or kind == "list") and "show-environment" or "set-environment" }
    for _, flag in ipairs(resolved.flags) do
        argv[#argv + 1] = flag
    end
    if kind == "get" or kind == "list" then
        argv[#argv + 1] = "-s"
    end
    if hidden then
        argv[#argv + 1] = "-h"
    end
    if kind == "unset" or kind == "remove" then
        argv[#argv + 1] = kind == "unset" and "-u" or "-r"
    end
    if name then
        argv[#argv + 1], argv[#argv + 2] = "--", name
        if kind == "set" then
            argv[#argv + 1] = value
        end
    end
    return argv
end

local function prepare(state, owned, kind, name, value, options)
    local function invalid(code, message)
        error(failure(kind, code, message), 0)
    end
    if not kinds[kind] then
        invalid("invalid_argument", "unknown environment operation")
    end
    if options ~= nil and not plain(options) then
        invalid("invalid_options", "environment options must be a plain record")
    end
    options = options or {}
    local read = kind == "get" or kind == "list"
    for key, item in next, options do
        if key == "scope" then
            if type(item) ~= "string" then
                invalid("invalid_scope", "environment scope must be a string")
            end
        elseif
            key == "inherit" and read
            or key == "include_hidden" and kind == "list"
            or key == "hidden" and kind == "set"
        then
            if type(item) ~= "boolean" then
                invalid("invalid_options", "environment switches must be booleans")
            end
        elseif key ~= "process" then
            invalid("invalid_options", "unsupported environment option")
        end
    end
    if kind == "list" then
        if name ~= nil then
            invalid("invalid_argument", "environment list does not take a name")
        end
    elseif type(name) ~= "string" or #name > 256 or not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
        invalid(
            "unsupported_name",
            "environment names must be portable identifiers of at most 256 bytes"
        )
    end
    if kind == "set" then
        if type(value) ~= "string" or #value > MAX_BYTES or value:find("\000", 1, true) then
            invalid(
                "invalid_argument",
                "environment value must be a NUL-free byte string of at most one MiB"
            )
        end
    elseif value ~= nil then
        invalid("invalid_argument", "only environment set takes a value")
    end
    local resolved, err = scope.resolve(state, owned, options.scope, "environment")
    if not resolved then
        error(err, 0)
    end
    if options.inherit and resolved.scope ~= "session" then
        invalid("invalid_options", "environment inheritance requires a session")
    end
    if read then
        local supported
        supported, err = codec.decode("", state.version, { hidden = false })
        if not supported then
            err = assert(err)
            error(failure(kind, err.code, err.message, nil, err, resolved.target), 0)
        end
    end
    local configured = { max_output_bytes = MAX_BYTES }
    if options.process ~= nil then
        if not plain(options.process) then
            invalid("invalid_options", "process options must be a plain record")
        end
        for key, item in next, options.process do
            if not process_fields[key] then
                invalid("invalid_options", "unsupported environment process option")
            end
            configured[key] = item
        end
        if
            type(configured.max_output_bytes) ~= "number"
            or configured.max_output_bytes > MAX_BYTES
        then
            invalid("invalid_options", "environment output limit must not exceed one MiB")
        end
    end
    local copied, opts, bytes = execution.prepare(
        state.runtime,
        { command(resolved, kind, name, value, options.hidden) },
        configured,
        false
    )
    if not copied then
        error(opts, 0)
    end
    return {
        argv = copied[1],
        process = opts,
        bytes = bytes,
        resolved = resolved,
        requested = options.scope,
        inherit = options.inherit == true,
        include_hidden = options.include_hidden ~= false,
        name = name,
    }
end

local function output_bytes(result, err)
    local total, seen = 0, {}
    local function account(item)
        if type(item) == "table" and not seen[item] then
            seen[item] = true
            local stdout, stderr = rawget(item, "stdout"), rawget(item, "stderr")
            if type(stdout) == "string" and type(stderr) == "string" then
                total = total + #stdout + #stderr
            end
        end
    end
    account(result)
    local depth = 0
    while type(err) == "table" and not seen[err] and depth < 16 do
        seen[err], depth = true, depth + 1
        account(rawget(err, "partial"))
        err = rawget(err, "cause")
    end
    return total
end

local function unknown(err, name)
    local partial = err and err.partial
    return err
        and err.code == "exit_failed"
        and type(partial) == "table"
        and partial.exit_code == 1
        and partial.signal == 0
        and partial.stdout == ""
        and partial.stderr == "unknown variable: " .. name .. "\n"
end

local function perform(state, owned, kind, plan, operation)
    local effect, wire_bytes, source_rows = "not_sent", 0, 0
    local function fail(code, message, cause)
        error(failure(kind, code, message, effect, cause, plan.resolved.target), 0)
    end
    local function check()
        local now, err = scope.resolve(state, owned, plan.requested, "environment")
        if not now then
            err = assert(err)
            fail(err.code, err.message, err)
        end
        now = assert(now)
        if not rawequal(now.target.generation, plan.resolved.target.generation) then
            fail("stale_generation", "server generation changed during environment operation")
        end
    end
    local function invoke(argv, grouped)
        check()
        effect = "unknown"
        operation:_set_effect(effect)
        local result, err
        if grouped then
            result, err = state.bound:group(argv, plan.process):await()
        else
            result, err = state.bound:execute(argv, plan.process):await()
        end
        effect = result and "completed" or err and err.effect or "unknown"
        operation:_set_effect(effect)
        wire_bytes = wire_bytes + output_bytes(result, err)
        if wire_bytes > MAX_BYTES then
            fail("frame_limit", "aggregate environment output exceeds one MiB")
        end
        result, err = process.retain_output(operation, result, err, "environment." .. kind)
        if not result and err and err.code == "queue_full" then
            error(err, 0)
        end
        return result, err
    end
    local function decoded(text, hidden, source, verification)
        local rows, err = codec.decode(text, state.version, { hidden = hidden })
        if not rows then
            err = assert(err)
            fail(verification and "inconsistent" or err.code, err.message, err)
        end
        rows = assert(rows)
        if source then
            source_rows = source_rows + #rows
            if source_rows > MAX_ROWS then
                fail("frame_limit", "aggregate environment entries exceed 4096")
            end
        end
        local bytes = 0
        for _, row in ipairs(rows) do
            bytes = bytes + 128 + #row.name + #(row.value or "")
        end
        local accepted, cause = operation:_retain(bytes)
        if not accepted then
            fail("queue_full", "decoded environment exceeds runtime byte capacity", cause)
        end
        return rows
    end
    local function record(row, resolved, inherited)
        row.scope, row.inherited = resolved.scope, inherited
        if resolved.scope == "session" then
            row.target = {
                kind = "session",
                id = resolved.target.id,
                generation = resolved.target.generation,
            }
        end
        return row
    end
    local function named(resolved, name, inherited)
        local result, err = invoke(command(resolved, "get", name))
        if not result then
            if unknown(err, name) then
                local accepted, cause = operation:_retain(128 + #name)
                if not accepted then
                    fail("queue_full", "environment record exceeds runtime byte capacity", cause)
                end
                return record({ name = name, state = "absent" }, resolved, inherited)
            end
            error(err, 0)
        end
        local hidden = false
        if result.stdout == "" then
            hidden = true
            result, err = invoke(command(resolved, "get", name, nil, true))
            if not result then
                if unknown(err, name) then
                    fail("inconsistent", "environment visibility changed during named read", err)
                end
                error(err, 0)
            end
        end
        local rows = decoded(result.stdout, hidden, true)
        if #rows ~= 1 or rows[1].name ~= name then
            fail("inconsistent", "named environment read did not match its target")
        end
        return record(rows[1], resolved, inherited)
    end
    local function verify(resolved, rows, hidden)
        local names = {}
        for _, row in ipairs(rows) do
            if row.state == "removed" then
                names[#names + 1] = row.name
            end
        end
        for first = 1, #names, VERIFY_GROUP do
            local commands, expected = {}, {}
            for index = first, math.min(first + VERIFY_GROUP - 1, #names) do
                commands[#commands + 1] = command(resolved, "get", names[index], nil, hidden)
                expected[#expected + 1] = names[index]
            end
            local result, err = invoke(commands, true)
            if not result then
                fail("inconsistent", "environment removal verification failed", err)
            end
            result = assert(result)
            if result.exit_code ~= 0 or result.signal ~= 0 then
                fail(
                    "inconsistent",
                    "environment removal verification failed",
                    errors.new(
                        "exit_failed",
                        "verification group exited unsuccessfully",
                        { effect = "completed", partial = result }
                    )
                )
            end
            -- Retain verification rows too; they are not additional stored entries.
            local actual = decoded(result.stdout, hidden, false, true)
            if #actual ~= #expected then
                fail("inconsistent", "environment removal verification changed the record count")
            end
            table.sort(actual, function(left, right)
                return left.name < right.name
            end)
            table.sort(expected)
            for index, row in ipairs(actual) do
                if row.name ~= expected[index] or row.state ~= "removed" then
                    fail(
                        "inconsistent",
                        "environment removal verification did not match the listing"
                    )
                end
            end
        end
    end
    local function listing(resolved, inherited, include_hidden)
        local views, by_name = {}, {}
        for _, hidden in ipairs(include_hidden and { false, true } or { false }) do
            local result, err = invoke(command(resolved, "list", nil, nil, hidden))
            if not result then
                error(err, 0)
            end
            local rows = decoded(result.stdout, hidden, true)
            views[#views + 1] = { rows = rows, hidden = hidden }
            for _, row in ipairs(rows) do
                if by_name[row.name] then
                    fail("inconsistent", "environment name appeared in both visibility views")
                end
                by_name[row.name] = record(row, resolved, inherited)
            end
        end
        for _, view in ipairs(views) do
            verify(resolved, view.rows, view.hidden)
        end
        return by_name
    end
    local result
    local global = { scope = "global", flags = { "-g" } }
    if kind == "get" then
        result = named(plan.resolved, plan.name, false)
        if result.state == "absent" and plan.inherit then
            local fallback = named(global, plan.name, true)
            if fallback.state ~= "absent" then
                result = fallback
            end
        end
    elseif kind == "list" then
        local entries = listing(plan.resolved, false, plan.include_hidden or plan.inherit)
        if plan.inherit then
            local fallback = listing(global, true, plan.include_hidden)
            for name, row in pairs(fallback) do
                if not entries[name] then
                    entries[name] = row
                end
            end
        end
        result = {}
        for _, row in pairs(entries) do
            if plan.include_hidden or not row.hidden then
                result[#result + 1] = row
            end
        end
        table.sort(result, function(left, right)
            return left.name < right.name
        end)
    else
        local receipt, err = invoke(plan.argv)
        if not receipt then
            error(err, 0)
        end
        result = true
    end
    check()
    return result
end

function M.run(state, owned, kind, name, value, options)
    local ok, plan = pcall(prepare, state, owned, kind, name, value, options)
    local request = state.runtime:_operation(function(_, operation)
        if not ok then
            return nil, plan
        end
        return perform(state, owned, kind, plan, operation)
    end, {
        operation = "environment." .. tostring(kind),
        effect = "not_sent",
        target = ok and plan.resolved.target or nil,
    })
    if ok and not request:is_settled() then
        local accepted, cause = request:_retain(plan.bytes)
        if not accepted then
            request:cancel(
                failure(
                    kind,
                    "queue_full",
                    "environment input exceeds runtime byte capacity",
                    nil,
                    cause,
                    plan.resolved.target
                )
            )
        end
    end
    return request
end

---@class libtmux.EnvironmentRecord
---@field name string Portable environment identifier.
---@field state "absent"|"value"|"removed"
---@field value? string Exact bytes, present only for value records; may be empty.
---@field hidden? boolean Absent records have no visibility flag.
---@field scope "global"|"session" Storage source, including for inherited records.
---@field inherited boolean True only for a global fallback requested through a session.
---@field target? libtmux.Reference Session storage identity; omitted for global storage.

---@class libtmux.EnvironmentOptions
---@field scope? "global"|"session" Must match the receiving handle.
---@field process? libtmux.CreationProcessOptions
---@field inherit? boolean Reads only; session fallback to global, default false.
---@field include_hidden? boolean Lists only; default true.
---@field hidden? boolean Set only; default false.

return M
