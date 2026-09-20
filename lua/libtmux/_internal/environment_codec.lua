local errors = require("libtmux._internal.error")
local M = {}
local MAX_BYTES, MAX_ROWS, MAX_NAME = 1048576, 4096, 256
local dialects = {
    ["3.2a"] = "raw",
    ["3.3"] = "raw",
    ["3.3a"] = "raw",
    ["3.4"] = "vis",
    ["3.5"] = "vis",
    ["3.5a"] = "vis",
    ["3.6"] = "raw",
    ["3.6a"] = "raw",
    ["3.6b"] = "raw",
    ["3.7"] = "raw",
    ["3.7a"] = "raw",
    ["3.7b"] = "raw",
    ["3.7c"] = "raw",
}
local controls = { a = "\a", b = "\b", f = "\f", r = "\r", v = "\v" }

local function failure(code, message, offset)
    return nil,
        errors.new(code, message, { operation = "environment.decode", offset = offset or 1 })
end

local function name_error(name, offset)
    if #name > MAX_NAME then
        return failure("frame_limit", "environment name exceeds 256 bytes", offset)
    end
    if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
        return failure(
            "unsupported_name",
            "environment listing contains a nonportable name",
            offset
        )
    end
    return true
end

local function quoted_value(data, offset, dialect)
    local parts, chunks = {}, {}
    local function append(value)
        if value ~= "" then
            parts[#parts + 1] = value
            if #parts == 128 then
                chunks[#chunks + 1], parts = table.concat(parts), {}
            end
        end
    end
    while offset <= #data do
        local found = data:find('[\\"$`]', offset)
        if not found then
            return failure("invalid_frame", "environment value has no closing quote", offset)
        end
        append(data:sub(offset, found - 1))
        local byte = data:sub(found, found)
        if byte == '"' then
            chunks[#chunks + 1] = table.concat(parts)
            return table.concat(chunks), found + 1
        elseif byte ~= "\\" then
            return failure("invalid_frame", "environment value contains an unescaped byte", found)
        end
        local escaped = data:sub(found + 1, found + 1)
        offset = found + 2
        -- Decode shell quoting and 3.4-3.5a printer escapes together: an original
        -- backslash was doubled before the printer added its own escape bytes.
        if escaped ~= "" and ('\\$`"'):find(escaped, 1, true) then
            append(escaped)
        elseif dialect == "vis" and controls[escaped] then
            append(controls[escaped])
        elseif dialect == "vis" and escaped:match("^[0-7]$") then
            local digits = data:sub(found + 1, found + 3)
            local number = digits:match("^[0-7][0-7][0-7]$") and tonumber(digits, 8)
            if not number or number == 0 or number > 255 then
                return failure(
                    "invalid_frame",
                    "environment value has an invalid octal escape",
                    found
                )
            end
            append(string.char(number))
            offset = found + 4
        else
            return failure("invalid_frame", "environment value has an unknown escape", found)
        end
    end
    return failure("invalid_frame", "environment value ends inside a quote", offset)
end

-- Removal rows are only parsed claims. A caller publishing a listing must
-- verify each name in the same native scope and visibility; this stream can
-- also represent one nonportable removed name containing embedded newlines.
function M.decode(data, version, options)
    local dialect = type(version) == "string" and dialects[version]
    if not dialect then
        return failure("unsupported_version", "environment printer version is not supported")
    end
    if
        type(options) ~= "table"
        or getmetatable(options) ~= nil
        or type(rawget(options, "hidden")) ~= "boolean"
    then
        return failure("invalid_options", "environment view requires a plain hidden boolean")
    end
    for key in next, options do
        if key ~= "hidden" then
            return failure("invalid_options", "unknown environment view option")
        end
    end
    if type(data) ~= "string" then
        return failure("invalid_frame", "environment output must be a byte string")
    end
    if #data > MAX_BYTES then
        return failure("frame_limit", "environment output exceeds one MiB")
    end
    local nul = data:find("\000", 1, true)
    if nul then
        return failure("invalid_frame", "environment output contains NUL", nul)
    end
    -- 3.4 adds one outer slash before variable-like dollars, after the
    -- environment printer has already quoted its own dollar and slash bytes.
    if version == "3.4" then
        data = data:gsub("\\(%$[A-Za-z_{])", "%1")
    end
    local rows, names, offset, payload = {}, {}, 1, 0
    while offset <= #data do
        if #rows >= MAX_ROWS then
            return failure("frame_limit", "environment output exceeds 4096 rows", offset)
        end
        local start, state = offset, "value"
        local name, value
        if data:sub(offset, offset + 5) == "unset " then
            local finish = data:find(";\n", offset + 6, true)
            if not finish then
                return failure("invalid_frame", "environment removal has no terminator", offset)
            end
            name, state, offset = data:sub(offset + 6, finish - 1), "removed", finish + 2
        else
            local finish = data:find('="', offset, true)
            if not finish then
                return failure("invalid_frame", "environment assignment has no value", offset)
            end
            name = data:sub(offset, finish - 1)
            local valid, err = name_error(name, start)
            if not valid then
                return nil, err
            end
            value, offset = quoted_value(data, finish + 2, dialect)
            if value == nil then
                return nil, offset
            end
            local suffix = "; export " .. name .. ";\n"
            if data:sub(offset, offset + #suffix - 1) ~= suffix then
                return failure(
                    "invalid_frame",
                    "environment export does not match its name",
                    offset
                )
            end
            offset = offset + #suffix
        end
        local valid, err = name_error(name, start)
        if not valid then
            return nil, err
        end
        if names[name] then
            return failure("invalid_frame", "environment output repeats a name", start)
        end
        names[name] = true
        payload = payload + #name + (value and #value or 0)
        if payload > MAX_BYTES then
            return failure("frame_limit", "environment payload exceeds one MiB", start)
        end
        rows[#rows + 1] = { name = name, state = state, hidden = options.hidden, value = value }
    end
    return rows
end

return M
