local fields = require("libtmux._internal.fields")
local codec = require("libtmux._internal.codec")
local errors = require("libtmux._internal.error")
local NULL = require("libtmux._internal.query").NULL
local M = {}
local projections = setmetatable({}, { __mode = "k" })

local function failure(code, message, context)
    context = context or {}
    context.operation = "metadata"
    return nil, errors.new(code, message, context)
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

function M.projection(kind, version, names)
    local schema, err = fields.schema(kind, version)
    if not schema then
        return nil, err
    end
    if type(names) ~= "table" or getmetatable(names) ~= nil then
        return failure("invalid_projection", "metadata fields must be a plain sequence")
    end
    local count = 0
    for key in next, names do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key > 1024 or key % 1 ~= 0 or count > 1024 then
            return failure("invalid_projection", "metadata fields must be a bounded dense sequence")
        end
    end
    if count == 0 then
        return failure("invalid_projection", "metadata projection needs at least one field")
    end
    local catalog = assert(fields.catalog(kind))
    local definitions = assert(schema.fields)
    local copied, formats, seen = {}, {}, {}
    for index = 1, count do
        local name = rawget(names, index)
        if type(name) ~= "string" or seen[name] then
            return failure("invalid_projection", "metadata projection needs distinct field names")
        end
        local field = definitions[name]
        if not field then
            return failure("unknown_field", "unknown metadata field", { field = name })
        elseif not field.supported then
            return failure(
                "unsupported_field",
                "metadata field is unavailable in this tmux version",
                { field = name }
            )
        end
        copied[index], formats[index], seen[name] = name, catalog[name].format, true
    end
    local format, format_error = codec.format(formats)
    if not format then
        return nil, format_error
    end
    local projection = {}
    projections[projection] = { names = copied, schema = schema, format = format }
    return projection
end

local function state(projection)
    return type(projection) == "table" and projections[projection] or nil
end

function M.format(projection)
    local stored = state(projection)
    if not stored then
        return failure("invalid_projection", "metadata projection is not recognized")
    end
    return stored.format
end

function M.schema(projection)
    local stored = state(projection)
    if not stored then
        return failure("invalid_projection", "metadata projection is not recognized")
    end
    return copy(stored.schema)
end

local function scalar(value, definition)
    if value == "" and definition.nullable then
        return NULL
    elseif definition.type == "string" then
        return value
    elseif definition.type == "boolean" then
        if value == "0" then
            return false
        elseif value == "1" then
            return true
        end
    elseif definition.type == "number" and value:match("^-?%d+$") then
        local number = tonumber(value)
        if number and number >= -9007199254740991 and number <= 9007199254740991 then
            return number
        end
    end
    return nil
end

function M.decode(data, projection, limits)
    local stored = state(projection)
    if not stored then
        return failure("invalid_projection", "metadata projection is not recognized")
    end
    local raw, err = codec.decode(data, #stored.names, limits)
    if not raw then
        return nil, err
    end
    local rows = {}
    for index, values in ipairs(raw) do
        local row = {}
        for column, name in ipairs(stored.names) do
            local definition = stored.schema.fields[name]
            local value = scalar(values[column], definition)
            if value == nil then
                return failure("invalid_metadata", "metadata field has an invalid scalar value", {
                    row = index,
                    field = name,
                    expected = definition.type,
                })
            end
            row[name] = value
        end
        rows[index] = row
    end
    return rows
end

return M
