local errors = require("libtmux._internal.error")
local execution = require("libtmux._internal.execution")
local identity = require("libtmux._internal.identity")
local process = require("libtmux._internal.process")
local M = {}
local versions = {
    ["3.2a"] = 2,
    ["3.3"] = 3,
    ["3.3a"] = 3,
    ["3.4"] = 4,
    ["3.5"] = 5,
    ["3.5a"] = 5,
    ["3.6"] = 6,
    ["3.6a"] = 6,
    ["3.6b"] = 6,
    ["3.7"] = 7,
    ["3.7a"] = 7,
    ["3.7b"] = 7,
    ["3.7c"] = 7,
}
local allowed = {
    rename = {},
    kill = {},
    renumber_windows = {},
    navigate_window = { activity = true },
    resize = {
        width = true,
        height = true,
        direction = true,
        amount = true,
        largest = true,
        smallest = true,
    },
    layout = { named = true, layout = true, next = true, previous = true, restore = true },
}
local targets = {
    session = {
        rename = "rename-session",
        kill = "kill-session",
        renumber_windows = "move-window",
        navigate_window = true,
    },
    window = {
        rename = "rename-window",
        kill = "kill-window",
        resize = "resize-window",
        layout = "select-layout",
    },
}
local layouts = {
    ["even-horizontal"] = 2,
    ["even-vertical"] = 2,
    ["main-horizontal"] = 2,
    ["main-vertical"] = 2,
    tiled = 2,
    ["main-horizontal-mirrored"] = 5,
    ["main-vertical-mirrored"] = 5,
}

local function operation(ref, kind)
    return (ref and ref.kind or "topology") .. "." .. (type(kind) == "string" and kind or "invalid")
end

local function failure(code, message, ref, kind, effect, details)
    details = details or {}
    details.operation, details.effect, details.target =
        operation(ref, kind), effect or "not_sent", ref
    return errors.new(code, message, details)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

local function current(state, owned, kind)
    if state.closed then
        return nil, failure("closed", "server handle is closed", nil, kind)
    end
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    local ref
    ref, err = identity.inspect(generation, owned)
    if not ref then
        return nil, err
    end
    if not targets[ref.kind] or not targets[ref.kind][kind] then
        return nil,
            failure("invalid_target", "operation is unavailable on this entity kind", ref, kind)
    end
    return ref
end

local function prepare(state, ref, kind, input, options)
    local function invalid(message, code)
        error(failure(code or "invalid_options", message, ref, kind), 0)
    end
    local version = type(state.version) == "string" and versions[state.version]
    if not version then
        invalid("topology operations require a supported exact tmux release", "unsupported_version")
    end
    options = options == nil and {} or options
    if not plain(options) then
        invalid("topology options must be a plain record")
    end
    for key in next, options do
        if key ~= "process" and not allowed[kind][key] then
            invalid("unknown topology option")
        end
    end
    if kind ~= "rename" and kind ~= "navigate_window" and input ~= nil then
        invalid("this topology operation does not take an input value", "invalid_argument")
    end
    local argv = { targets[ref.kind][kind], "-t", ref.id }
    local function flag(name, value)
        argv[#argv + 1] = name
        if value ~= nil then
            argv[#argv + 1] = type(value) == "number" and string.format("%.0f", value) or value
        end
    end
    local function bytes(value, maximum)
        if
            type(value) ~= "string"
            or #value == 0
            or #value > maximum
            or value:find("\000", 1, true)
        then
            invalid("value must be bounded nonempty NUL-free bytes", "invalid_argument")
        end
        return value
    end
    local function boolean(name)
        if options[name] ~= nil and type(options[name]) ~= "boolean" then
            invalid(name .. " must be boolean")
        end
        return options[name] == true
    end
    if kind == "rename" then
        bytes(input, 1024)
        if ref.kind == "session" and input:find("[.:\001-\031\127]") then
            invalid(
                "session names cannot contain dots, colons or control bytes",
                "invalid_argument"
            )
        end
        flag("--", (input:gsub("#", "##")))
    elseif kind == "navigate_window" then
        local navigation =
            { next = "next-window", previous = "previous-window", last = "last-window" }
        if type(input) ~= "string" or not navigation[input] then
            invalid("window navigation requires next, previous or last", "invalid_argument")
        end
        argv[1] = navigation[input]
        if input == "last" and options.activity ~= nil then
            invalid("last-window does not accept activity filtering")
        end
        if boolean("activity") then
            flag("-a")
        end
    elseif kind == "renumber_windows" then
        flag("-r")
    elseif kind == "resize" then
        local largest, smallest = boolean("largest"), boolean("smallest")
        local dimensions = options.width ~= nil or options.height ~= nil
        local modes = (dimensions and 1 or 0)
            + (options.direction ~= nil and 1 or 0)
            + (largest and 1 or 0)
            + (smallest and 1 or 0)
        if modes ~= 1 or options.amount ~= nil and options.direction == nil then
            invalid("resize requires exactly one of dimensions, direction, largest or smallest")
        end
        if dimensions then
            for _, item in ipairs({ { "width", "-x" }, { "height", "-y" } }) do
                local value = options[item[1]]
                if value ~= nil then
                    if not integer(value, 1, 10000) then
                        invalid("window dimensions must be integers from 1 to 10000")
                    end
                    flag(item[2], value)
                end
            end
        elseif options.direction ~= nil then
            local directions = { left = "-L", right = "-R", up = "-U", down = "-D" }
            local direction = directions[options.direction]
            local amount = options.amount == nil and 1 or options.amount
            if not direction or not integer(amount, 1, 10000) then
                invalid("resize needs a direction and an integer amount from 1 to 10000")
            end
            flag(direction, amount)
        else
            flag(largest and "-A" or "-a")
        end
    elseif kind == "layout" then
        local next_layout, previous, restore =
            boolean("next"), boolean("previous"), boolean("restore")
        local modes = (options.named ~= nil and 1 or 0)
            + (options.layout ~= nil and 1 or 0)
            + (next_layout and 1 or 0)
            + (previous and 1 or 0)
            + (restore and 1 or 0)
        if modes ~= 1 then
            invalid("layout requires exactly one of named, layout, next, previous or restore")
        end
        if options.named ~= nil then
            local minimum = type(options.named) == "string" and layouts[options.named]
            if not minimum then
                invalid("named layout must use a full canonical name", "invalid_argument")
            elseif version < minimum then
                invalid("named layout is unavailable on this tmux release", "unsupported")
            end
            flag("--", options.named)
        elseif options.layout ~= nil then
            local layout = bytes(options.layout, 65536)
            -- Older native parsers read past short headers; 3.3/3.3a also
            -- leave the error cause unset when the checksum header is absent.
            if not layout:match("^%x%x%x%x,.") then
                invalid("custom layout requires a four-digit checksum and body", "invalid_layout")
            end
            flag("--", layout)
        else
            flag(next_layout and "-n" or previous and "-p" or "-o")
        end
    end
    if options.process ~= nil then
        if not plain(options.process) then
            invalid("process options must be a plain record")
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
                invalid("unsupported topology process option")
            end
        end
    end
    local copied, configured, cost =
        execution.prepare(state.runtime, { argv }, options.process, false)
    if not copied then
        error(configured, 0)
    end
    if cost > 1048576 then
        invalid("topology input exceeds one MiB")
    end
    return { argv = copied[1], options = configured, bytes = cost }
end

function M.run(state, owned, kind, input, options)
    local ref, validation_error, plan
    if type(kind) ~= "string" or not allowed[kind] then
        validation_error = failure("invalid_operation", "unknown topology operation", nil, kind)
    else
        ref, validation_error = current(state, owned, kind)
        if ref then
            local ok, value = pcall(prepare, state, ref, kind, input, options)
            if ok then
                plan = value
            else
                validation_error = value
            end
        end
    end
    local request = state.runtime:_operation(function(_, active)
        if not plan or not ref then
            return nil, validation_error
        end
        local now, err = current(state, owned, kind)
        if not now then
            return nil, err
        end
        if not rawequal(ref.generation, now.generation) then
            return nil,
                failure(
                    "stale_generation",
                    "server generation changed before topology operation",
                    ref,
                    kind
                )
        end
        -- Native aliases and hooks can change behavior or wait; submission is
        -- not a transaction and a nonzero exit does not establish rollback.
        active:_set_effect("unknown")
        local result
        result, err = state.bound:execute(plan.argv, plan.options):await()
        result, err = process.retain_output(active, result, err, operation(ref, kind))
        if not result then
            return nil, err
        end
        active:_set_effect("completed")
        now, err = current(state, owned, kind)
        if not now or not rawequal(ref.generation, now.generation) then
            return nil,
                failure(
                    err and err.code or "stale_generation",
                    err and err.message or "server generation changed after topology operation",
                    ref,
                    kind,
                    "completed",
                    { cause = err, partial = result }
                )
        end
        return true
    end, { operation = operation(ref, kind), effect = "not_sent", target = ref })
    if plan and not request:is_settled() then
        local accepted, cause = request:_retain(plan.bytes)
        if not accepted then
            request:cancel(
                failure(
                    "queue_full",
                    "topology input exceeds runtime byte capacity",
                    ref,
                    kind,
                    nil,
                    { cause = cause }
                )
            )
        end
    end
    return request
end

---@class libtmux.TopologyOptions
---@field process? libtmux.CreationProcessOptions

---@class libtmux.NavigateWindowOptions: libtmux.TopologyOptions
---@field activity? boolean Only next/previous accept this option, including false.

---@class libtmux.ResizeWindowOptions: libtmux.TopologyOptions
---@field width? integer From 1 to 10000; dimensions exclude direction and policies.
---@field height? integer From 1 to 10000.
---@field direction? 'left'|'right'|'up'|'down'
---@field amount? integer From 1 to 10000; defaults to 1 with direction.
---@field largest? boolean Native largest sizing; excludes dimensions and other modes.
---@field smallest? boolean Native smallest sizing; excludes dimensions and other modes.

---@alias libtmux.NamedLayout
---| 'even-horizontal'
---| 'even-vertical'
---| 'main-horizontal'
---| 'main-vertical'
---| 'tiled'
---| 'main-horizontal-mirrored'
---| 'main-vertical-mirrored'

---@class libtmux.LayoutOptions: libtmux.TopologyOptions
---@field named? libtmux.NamedLayout
---@field layout? string Exported checksum-prefixed layout; native validation can unzoom first.
---@field next? boolean Select exactly one of named/layout/next/previous/restore.
---@field previous? boolean
---@field restore? boolean

return M
