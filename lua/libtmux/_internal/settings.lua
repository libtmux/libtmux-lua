local errors = require("libtmux._internal.error")
local scope = require("libtmux._internal.scope")
local catalog = require("libtmux._internal.options_catalog")
local codec = require("libtmux._internal.option_codec")
local command = require("libtmux._internal.command")
local execution = require("libtmux._internal.execution")
local process = require("libtmux._internal.process")
local M = {}
local MAX_BYTES = 1048576

local function failure(code, message, effect)
    return errors.new(code, message, { operation = "settings", effect = effect or "not_sent" })
end

local function fail(code, message)
    error(failure(code, message), 0)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

local function bytes(value)
    if type(value) ~= "string" or #value > MAX_BYTES or value:find("\000", 1, true) then
        fail("invalid_value", "option values must be bounded NUL-free strings")
    end
    return value
end

local function definition(version, name, family)
    if type(name) ~= "string" or #name > 256 then
        return nil, failure("invalid_option", "option name must be a bounded canonical name")
    end
    if name:sub(1, 1) == "@" then
        if not name:match("^@[A-Za-z0-9_][A-Za-z0-9_.%-]*$") then
            return nil,
                failure(
                    "unsupported_name",
                    "user option name must contain portable name characters"
                )
        end
        return {
            name = name,
            native_type = "string",
            array = false,
            hook = family == "hook",
            user = true,
        }
    end
    local value, err = catalog.lookup(version, name)
    if not value then
        return nil, err
    end
    if family == "hook" and not value.hook then
        return nil, failure("invalid_hook", "name does not identify a hook")
    elseif family == "option" and value.hook then
        return nil, failure("invalid_option", "hook programs require the hook methods")
    end
    return value
end

local function string_value(def, value)
    local kind = def.native_type
    if kind == "flag" then
        if type(value) ~= "boolean" then
            fail("invalid_value", "flag options require a boolean")
        end
        return value and "on" or "off"
    elseif kind == "number" then
        if not integer(value, def.minimum, def.maximum) then
            fail("invalid_value", "numeric option is outside its integer range")
        end
        return string.format("%.0f", value)
    elseif kind == "command" then
        local encoded, err = command.prepare_program(value)
        if not encoded then
            error(err, 0)
        end
        return encoded
    end
    bytes(value)
    if kind == "choice" then
        for _, choice in ipairs(def.choices) do
            if value == choice then
                return value
            end
        end
        fail("invalid_value", "option value is not an exact choice for this release")
    end
    return value
end

local function argv(verb, resolved, name, flag)
    local result = { verb }
    for _, value in ipairs(resolved.flags) do
        result[#result + 1] = value
    end
    if flag then
        result[#result + 1] = flag
    end
    result[#result + 1] = "--"
    if name then
        result[#result + 1] = name
    end
    return result
end

local function prepare(state, owned, family, kind, name, value, options)
    options = options == nil and {} or options
    if not plain(options) then
        fail("invalid_options", "settings options must be a plain record")
    end
    local read = kind == "get" or kind == "list"
    local allowed = { process = true }
    if kind ~= "run" then
        allowed.scope = true
    end
    if read then
        allowed.inherit = true
    end
    if kind ~= "list" and kind ~= "run" then
        allowed.index = true
    end
    if kind == "set" then
        allowed.append = true
    end
    for key in next, options do
        if not allowed[key] then
            fail("invalid_options", "unknown setting option")
        end
    end
    for _, key in ipairs({ "inherit", "append" }) do
        if options[key] ~= nil and type(options[key]) ~= "boolean" then
            fail("invalid_options", key .. " must be boolean")
        end
    end
    local inherit = read and options.inherit ~= false
    local resolved, err = scope.resolve(state, owned, options.scope, family)
    if not resolved then
        error(err, 0)
    end
    if kind == "run" and (family ~= "hook" or not owned) then
        fail("invalid_scope", "hook execution requires a session, window or pane context")
    end
    local names
    names, err = catalog.names(state.version)
    if not names then
        error(err, 0)
    end
    local def
    if kind ~= "list" then
        def, err = definition(state.version, name, family)
        if not def then
            error(err, 0)
        end
        -- Native -R selects a hook from the execution context, not storage flags.
        if not def.user and kind ~= "run" then
            local valid
            valid, err = scope.check_option(resolved, def)
            if not valid then
                error(err, 0)
            end
        end
    end
    local index = options.index
    if index ~= nil and (not def.array or not integer(index, 0, 2147483647)) then
        fail("invalid_index", "array index must be an integer from 0 to 2147483647")
    end
    local selected = index and (name .. "[" .. string.format("%.0f", index) .. "]") or name
    local commands = {}
    local verb = family == "hook" and "set-hook" or "set-option"
    if read then
        commands[1] = argv("show-options", resolved, name, family == "hook" and "-H" or nil)
        if inherit then
            commands[2] = argv("show-options", resolved, name, "-A")
            if family == "hook" then
                table.insert(commands[2], 2, "-H")
            end
        end
    elseif kind == "unset" then
        commands[1] = argv(verb, resolved, selected, "-u")
    elseif kind == "run" then
        if def.user and state.version == "3.2a" then
            fail("unsupported", "custom hook execution requires tmux 3.3 or newer")
        end
        commands[1] = { "set-hook", "-R", "-t", resolved.target.id, "--", name }
    elseif kind == "set" then
        local encoded
        if family == "hook" then
            if options.append and (def.user or index ~= nil) then
                fail("invalid_options", "hook append requires an unindexed built-in hook")
            end
            encoded, err = command.prepare_program(value)
            if not encoded then
                error(err, 0)
            end
        elseif def.array and index == nil then
            if not plain(value) then
                fail("invalid_value", "array replacement needs an entries record")
            end
            for key in next, value do
                if key ~= "entries" then
                    fail("invalid_value", "unknown array replacement field")
                end
            end
            if options.append then
                fail("unsupported", "whole-array append needs explicit indexed writes")
            end
            local entries = value.entries
            if not plain(entries) then
                fail("invalid_value", "array entries must be a dense sequence")
            end
            local count = 0
            for key in next, entries do
                count = count + 1
                if not integer(key, 1, 512) or count > 512 then
                    fail("invalid_value", "array replacement exceeds 512 entries")
                end
            end
            local clear = argv(verb, resolved, name)
            clear[#clear + 1] = ""
            commands[1] = clear
            local seen, prepared = {}, {}
            for position = 1, count do
                local entry = rawget(entries, position)
                if not plain(entry) then
                    fail("invalid_value", "array entries must be plain records")
                end
                for key in next, entry do
                    if key ~= "index" and key ~= "value" then
                        fail("invalid_value", "unknown array entry field")
                    end
                end
                local slot = entry.index
                if not integer(slot, 0, 2147483647) or seen[slot] then
                    fail("invalid_index", "array entries need distinct bounded indices")
                end
                seen[slot] = true
                prepared[#prepared + 1] = { index = slot, value = string_value(def, entry.value) }
            end
            table.sort(prepared, function(left, right)
                return left.index < right.index
            end)
            for _, entry in ipairs(prepared) do
                local slot = entry.index
                local item = argv(verb, resolved, name .. "[" .. string.format("%.0f", slot) .. "]")
                item[#item + 1] = entry.value
                commands[#commands + 1] = item
            end
        else
            if options.append and def.native_type ~= "string" then
                fail("invalid_options", "append requires a string option or array element")
            end
            encoded = string_value(def, value)
        end
        if encoded then
            local item = argv(verb, resolved, selected, options.append and "-a" or nil)
            item[#item + 1] = encoded
            commands[1] = item
        end
    else
        fail("invalid_operation", "unknown settings operation")
    end
    if options.process ~= nil then
        if not plain(options.process) then
            fail("invalid_options", "process options must be a plain record")
        end
        local permitted = {
            timeout = true,
            deadline = true,
            max_output_bytes = true,
            kill_timeout = true,
            drain_timeout = true,
        }
        for key in next, options.process do
            if not permitted[key] then
                fail("invalid_options", "unsupported settings process option")
            end
        end
    end
    local copied, configured, size =
        execution.prepare(state.runtime, commands, options.process, false)
    if not copied then
        error(configured, 0)
    end
    if size > MAX_BYTES then
        fail("invalid_value", "settings input exceeds one MiB")
    end
    assert(configured)
    configured.max_output_bytes = math.min(configured.max_output_bytes, MAX_BYTES)
    return {
        resolved = resolved,
        definition = def,
        commands = copied,
        process = configured,
        bytes = size,
        family = family,
        kind = kind,
        name = name,
        index = index,
        inherit = inherit,
        version = state.version,
    }
end

local function decode_value(def, text, version)
    if def.native_type == "string" then
        return codec.decode_string(text, version)
    end
    if def.native_type == "command" then
        return codec.command_source(text, version)
    end
    if def.native_type == "flag" then
        if text == "on" then
            return true
        elseif text == "off" then
            return false
        end
    elseif def.native_type == "number" then
        if text:match("^%-?%d+$") then
            local value = tonumber(text)
            if integer(value, def.minimum, def.maximum) then
                return value
            end
        end
    elseif def.native_type == "choice" then
        for _, choice in ipairs(def.choices) do
            if text == choice then
                return text
            end
        end
    elseif text ~= "" and not text:find("[%z\r\n]") then
        return text
    end
    return nil,
        failure("invalid_frame", "native option value does not match its catalog type", "completed")
end

local function parse(plan, output, inherited)
    if #output > MAX_BYTES or (output ~= "" and output:sub(-1) ~= "\n") then
        return nil,
            failure("invalid_frame", "option listing is oversized or truncated", "completed")
    end
    local records, order, rows = {}, {}, 0
    for line in output:gmatch("([^\n]*)\n") do
        rows = rows + 1
        if rows > 4096 then
            return nil, failure("output_limit", "option listing exceeds 4096 rows", "completed")
        end
        local heading, text = line:match("^([^ ]+) (.*)$")
        if not heading then
            heading = line
        end
        local parent = heading:sub(-1) == "*"
        if parent then
            heading = heading:sub(1, -2)
        end
        local name, digits = heading:match("^(.-)%[(%d+)%]$")
        name = name or heading
        local def, definition_error = definition(plan.version, name, plan.family)
        -- show-options -H includes ordinary options; show-hooks lacks -A on the floor.
        if not def then
            assert(definition_error)
            if not (plan.family == "hook" and definition_error.code == "invalid_hook") then
                definition_error.effect = "completed"
                return nil, definition_error
            end
        end
        if def and not (plan.kind == "list" and plan.family == "hook" and def.user) then
            if not def.user and not scope.check_option(plan.resolved, def) then
                return nil,
                    failure("invalid_frame", "option result has an unexpected scope", "completed")
            end
            if plan.name and name ~= plan.name then
                return nil,
                    failure("invalid_frame", "option result has an unexpected name", "completed")
            end
            local index = digits and tonumber(digits)
            if
                (index and (not def.array or not integer(index, 0, 2147483647)))
                or (not def.array and text == nil)
            then
                return nil,
                    failure(
                        "invalid_frame",
                        "option listing has an invalid index or value",
                        "completed"
                    )
            end
            local entry = records[name]
            if not entry then
                entry = {
                    name = name,
                    type = def.native_type,
                    present = true,
                    inherited = parent or inherited and text == nil or false,
                    scope = plan.resolved.scope,
                    target = plan.resolved.target,
                }
                if def.array then
                    entry.entries = {}
                    entry.empty_marker = text == nil
                end
                records[name], order[#order + 1] = entry, name
            elseif not def.array or text == nil or index == nil or entry.empty_marker then
                return nil,
                    failure(
                        "invalid_frame",
                        "option listing repeats a scalar or empty array",
                        "completed"
                    )
            end
            if text ~= nil then
                local value, err = decode_value(def, text, plan.version)
                if value == nil then
                    return nil, err
                end
                if def.array then
                    if not index or (entry.last_index and index <= entry.last_index) then
                        return nil,
                            failure(
                                "invalid_frame",
                                "array listing has repeated or unordered indices",
                                "completed"
                            )
                    end
                    entry.last_index = index
                    local item
                    if plan.family == "hook" then
                        item = { index = index, source = value }
                    else
                        item = { index = index, value = value }
                    end
                    entry.entries[#entry.entries + 1] = item
                else
                    entry[plan.family == "hook" and "source" or "value"] = value
                end
            elseif not def.array or index then
                return nil,
                    failure(
                        "invalid_frame",
                        "only whole arrays can have an empty listing",
                        "completed"
                    )
            end
        end
    end
    for _, value in pairs(records) do
        value.last_index = nil
        value.empty_marker = nil
    end
    return { records = records, order = order, rows = rows }
end

function M.run(state, owned, family, kind, name, value, options)
    local ok, plan = pcall(prepare, state, owned, family, kind, name, value, options)
    if not ok then
        plan = errors.wrap(plan, "invalid_options")
        plan.operation, plan.effect = family .. "." .. kind, "not_sent"
    end
    local request = state.runtime:_operation(function(_, operation)
        if not ok then
            return nil, plan
        end
        local current, err = scope.resolve(state, owned, plan.resolved.scope, family)
        if not current then
            return nil, err
        end
        if not rawequal(current.target.generation, plan.resolved.target.generation) then
            return nil,
                failure("stale_generation", "server generation changed before settings operation")
        end
        local output_bytes, decoded_rows = 0, 0
        local function call(commands, grouped)
            operation:_set_effect("unknown")
            local result, cause
            if grouped then
                result, cause = state.bound:group(commands, plan.process):await()
            else
                result, cause = state.bound:execute(commands, plan.process):await()
            end
            result, cause = process.retain_output(operation, result, cause, "settings")
            if not result then
                if
                    plan.definition
                    and plan.definition.user
                    and kind == "get"
                    and cause
                    and cause.code == "exit_failed"
                    and cause.partial
                    and cause.partial.stderr == "invalid option: " .. name .. "\n"
                then
                    result = { stdout = "", stderr = "", exit_code = 0, signal = 0 }
                else
                    return nil, cause
                end
            end
            operation:_set_effect("completed")
            output_bytes = output_bytes + #result.stdout + #result.stderr
            if output_bytes > MAX_BYTES then
                return nil, failure("output_limit", "settings output exceeds one MiB", "completed")
            end
            if result.exit_code ~= 0 or result.signal ~= 0 then
                return nil,
                    errors.new(
                        "exit_failed",
                        "tmux settings group failed",
                        { effect = "completed", operation = "settings", partial = result }
                    )
            end
            local valid, stale = scope.resolve(state, owned, plan.resolved.scope, family)
            if not valid then
                assert(stale)
                return nil,
                    errors.new(stale.code, stale.message, {
                        operation = "settings",
                        effect = "completed",
                        cause = stale,
                        partial = result,
                    })
            end
            return result
        end
        local function decoded(output, inherited)
            local values, cause = parse(plan, output, inherited)
            if not values then
                if cause then
                    cause.effect = "completed"
                end
                return nil, cause
            end
            decoded_rows = decoded_rows + values.rows
            if decoded_rows > 4096 then
                return nil,
                    failure(
                        "output_limit",
                        "aggregate option listing exceeds 4096 rows",
                        "completed"
                    )
            end
            local accepted, retained_error = operation:_retain(#output)
            if not accepted then
                return nil,
                    errors.new("queue_full", "decoded settings exceed runtime byte capacity", {
                        effect = "completed",
                        operation = "settings",
                        cause = retained_error,
                    })
            end
            return values
        end
        if kind ~= "get" and kind ~= "list" then
            local result
            result, err =
                call(#plan.commands == 1 and plan.commands[1] or plan.commands, #plan.commands > 1)
            if not result then
                return nil, err
            end
            return true
        end
        local result
        result, err = call(plan.commands[1])
        if not result then
            return nil, err
        end
        local local_values
        local_values, err = decoded(result.stdout, false)
        if not local_values then
            return nil, err
        end
        if plan.inherit and (kind == "list" or not local_values.records[name]) then
            result, err = call(plan.commands[2])
            if not result then
                return nil, err
            end
            local fallback
            fallback, err = decoded(result.stdout, true)
            if not fallback then
                return nil, err
            end
            for _, key in ipairs(fallback.order) do
                if not local_values.records[key] then
                    local_values.records[key] = fallback.records[key]
                    local_values.order[#local_values.order + 1] = key
                end
            end
        end
        if kind == "get" then
            local record = local_values.records[name]
            if not record then
                return {
                    name = name,
                    type = plan.definition.native_type,
                    present = false,
                    inherited = false,
                    scope = plan.resolved.scope,
                    target = plan.resolved.target,
                }
            end
            if plan.index then
                local entries = {}
                for _, item in ipairs(record.entries) do
                    if item.index == plan.index then
                        entries[1] = item
                        break
                    end
                end
                record.entries, record.present = entries, #entries == 1
            end
            return record
        end
        table.sort(local_values.order)
        local values = {}
        for _, key in ipairs(local_values.order) do
            values[#values + 1] = local_values.records[key]
        end
        return values
    end, {
        operation = family .. "." .. kind,
        effect = "not_sent",
        target = ok and plan.resolved.target or nil,
    })
    if ok and not request:is_settled() then
        local accepted, cause = request:_retain(plan.bytes)
        if not accepted then
            request:cancel(
                failure(
                    "queue_full",
                    "settings input exceeds runtime byte capacity: " .. tostring(cause)
                )
            )
        end
    end
    return request
end

---@class libtmux.HookProgram
---@field commands? string[][] Exactly one of commands or source.
---@field source? string Explicit tmux program text; never Lua code.

---@class libtmux.OptionEntry
---@field index integer Zero-based native array index.
---@field value string|number|boolean

---@class libtmux.OptionArrayInput
---@field entries {index:integer,value:string|number|boolean|libtmux.HookProgram}[]

---@alias libtmux.OptionInput string|number|boolean|libtmux.HookProgram|libtmux.OptionArrayInput

--- What every option and hook operation accepts. Each operation's own class
--- adds the fields it reads; anything else fails with `invalid_options`.
---@class libtmux.SettingOptions
---@field scope? 'server'|'session'|'window'|'pane'|'global_session'|'global_window'
---@field process? libtmux.CreationProcessOptions

---@class libtmux.SettingListOptions: libtmux.SettingOptions
---@field inherit? boolean Read fallback values; defaults to true.

---@class libtmux.SettingGetOptions: libtmux.SettingListOptions
---@field index? integer Array slot; reads still inspect the whole array.

---@class libtmux.SettingUnsetOptions: libtmux.SettingOptions
---@field index? integer Array slot.

---@class libtmux.SettingSetOptions: libtmux.SettingUnsetOptions
---@field append? boolean String concatenation or unindexed built-in hook append.

--- Running a hook reads only its handle's own scope.
---@class libtmux.RunHookOptions
---@field process? libtmux.CreationProcessOptions

---@class libtmux.OptionRecord
---@field name string
---@field type 'string'|'number'|'key'|'colour'|'flag'|'choice'|'command'
---@field scope string Requested storage scope.
---@field target libtmux.Reference
---@field present boolean False distinguishes absent from empty and false.
---@field inherited boolean
---@field value? string|number|boolean Canonical text for key, colour, style and command types.
---@field entries? libtmux.OptionEntry[] Ordered sparse entries; empty is distinct from absent.

---@class libtmux.HookRecord
---@field name string
---@field type 'command'|'string'
---@field scope string
---@field target libtmux.Reference
---@field present boolean
---@field inherited boolean
---@field source? string Stored program for a custom hook.
---@field entries? {index:integer,source:string}[] Canonical built-in hook programs.

return M
