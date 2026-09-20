local errors = require("libtmux._internal.error")
local M = {}
local generations = setmetatable({}, { __mode = "k" })
local handles = setmetatable({}, { __mode = "k" })
local kinds = {
    server = {},
    session = { id = "^%$%d+$" },
    window = { id = "^@%d+$" },
    pane = { id = "^%%%d+$" },
    window_link = { session_id = "^%$%d+$", window_id = "^@%d+$", index = "index" },
    client = { name = "name", tty = "bytes" },
    buffer = { name = "name" },
}

local function failure(code, message, fields)
    fields = fields or {}
    fields.operation, fields.effect = "reference", "not_sent"
    return nil, errors.new(code, message, fields)
end

local function copy(value)
    local result = {}
    for key, item in next, value do
        result[key] = item
    end
    return result
end

local function string_value(value, empty)
    return type(value) == "string"
        and (empty or #value > 0)
        and #value <= 4096
        and not value:find("\000", 1, true)
end

local function current(generation)
    local state = generations[generation]
    if not state then
        return failure("invalid_reference", "server generation is not owned by this connection")
    end
    if state.invalid then
        return failure("stale_generation", "server generation is no longer current", {
            reason = state.reason,
        })
    end
    return state
end

-- Evidence describes an observation; matching evidence never reuses a generation.
function M.generation(evidence)
    if type(evidence) ~= "table" or getmetatable(evidence) ~= nil then
        return failure("invalid_reference", "generation evidence must be a plain record")
    end
    for key in next, evidence do
        if key ~= "pid" and key ~= "started" and key ~= "socket" and key ~= "version" then
            return failure("invalid_reference", "unknown generation evidence field")
        end
    end
    for _, key in ipairs({ "pid", "started", "socket", "version" }) do
        if not string_value(rawget(evidence, key), false) then
            return failure("invalid_reference", "generation evidence requires " .. key)
        end
    end
    if not evidence.pid:match("^%d+$") or not evidence.started:match("^%d+$") then
        return failure("invalid_reference", "daemon PID and start time must be decimal strings")
    end
    local token = {}
    generations[token] = { evidence = copy(evidence) }
    return token
end

function M.evidence(generation)
    local state, err = current(generation)
    if not state then
        return nil, err
    end
    return copy(state.evidence)
end

function M.invalidate(generation, reason)
    local state = generations[generation]
    if not state or state.invalid then
        return false
    end
    state.invalid, state.reason = true, reason or "connection continuity lost"
    return true
end

function M.bind(generation, reference)
    local state, err = current(generation)
    if not state then
        return nil, err
    end
    if type(reference) ~= "table" or getmetatable(reference) ~= nil then
        return failure("invalid_reference", "reference must be a plain record")
    end
    local shape = kinds[reference.kind]
    if not shape then
        return failure("invalid_reference", "reference has an unknown entity kind")
    end
    if not rawequal(reference.generation, generation) then
        return failure("stale_generation", "reference belongs to another server generation")
    end
    for key in next, reference do
        if key ~= "generation" and key ~= "kind" and shape[key] == nil then
            return failure("invalid_reference", "unknown reference field")
        end
    end
    for key, rule in pairs(shape) do
        local value = rawget(reference, key)
        local valid
        if rule == "index" then
            valid = type(value) == "number"
                and value >= 0
                and value <= 2147483647
                and value % 1 == 0
        else
            valid = string_value(value, rule == "bytes")
            if valid and rule ~= "name" and rule ~= "bytes" then
                valid = value:match(rule) ~= nil
            end
        end
        if not valid then
            return failure("invalid_reference", "invalid reference field: " .. key)
        end
    end
    local handle = {}
    handles[handle] = copy(reference)
    return handle
end

-- Contextual references still require live linkage/name revalidation by the caller.
function M.inspect(generation, handle)
    local state, err = current(generation)
    if not state then
        return nil, err
    end
    local reference = handles[handle]
    if not reference then
        return failure("invalid_reference", "handle was not created from a validated reference")
    end
    if not rawequal(reference.generation, generation) then
        return failure("stale_generation", "handle belongs to another server generation")
    end
    return copy(reference)
end

return M
