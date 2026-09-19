local errors = require("libtmux._internal.error")
local M = {}
local marker = "LQ1\r$a;"
local quoted = "|&;<>()$`\\\"'*?[# =%"
local controls = { a = "\a", b = "\b", f = "\f", r = "\r", v = "\v" }

local function failure(code, message, offset)
    return nil, errors.new(code, message, { operation = "metadata", offset = offset or 1 })
end

local function integer(value, maximum)
    return type(value) == "number" and value > 0 and value <= maximum and value % 1 == 0
end

local function decode_field(data, start, finish, dialect)
    local parts, offset = {}, start
    while offset <= finish do
        local found = data:find("\\", offset, true)
        if not found or found > finish then
            parts[#parts + 1] = data:sub(offset, finish)
            break
        end
        parts[#parts + 1] = data:sub(offset, found - 1)
        local escaped = data:sub(found + 1, found + 1)
        offset = found + 2
        if dialect == "dollar" and data:sub(found + 1, found + 2) == "\\$" then
            escaped, offset = "$", found + 3
        elseif dialect ~= "raw" and escaped:match("[0-7]") then
            local digits = data:sub(found + 1, found + 3)
            local byte = tonumber(digits, 8)
            if
                #digits ~= 3
                or not digits:match("^[0-7][0-7][0-7]$")
                or not byte
                or byte == 0
                or byte > 255
            then
                return failure("invalid_frame", "metadata has an invalid octal escape", found)
            end
            escaped, offset = string.char(byte), found + 4
        elseif dialect ~= "raw" and controls[escaped] then
            escaped = controls[escaped]
        elseif escaped == "" or not quoted:find(escaped, 1, true) then
            return failure("invalid_frame", "metadata has an unknown escape", found)
        end
        if offset > finish + 1 then
            return failure("invalid_frame", "metadata ends inside an escape", found)
        end
        parts[#parts + 1] = escaped
    end
    return table.concat(parts)
end

function M.format(fields)
    if type(fields) ~= "table" or getmetatable(fields) ~= nil then
        return failure("invalid_format", "format fields must be a plain sequence")
    end
    local count = 0
    for key in next, fields do
        count = count + 1
        if not integer(key, 1024) or count > 1024 then
            return failure("invalid_format", "format fields must be a bounded dense sequence")
        end
    end
    if count == 0 then
        return failure("invalid_format", "at least one format field is required")
    end
    local parts = {}
    for index = 1, count do
        local name = rawget(fields, index)
        if type(name) ~= "string" or not name:match("^@?[a-z][a-z0-9_]*$") then
            return failure("invalid_format", "format field names cannot contain expressions", index)
        end
        parts[index] = "#{q:" .. name .. "};"
    end
    return marker .. table.concat(parts) .. "."
end

function M.decode(data, field_count, options)
    if options == nil then
        options = {}
    end
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return failure("invalid_options", "metadata limits must be a plain table")
    end
    for key in next, options do
        if key ~= "max_bytes" and key ~= "max_rows" then
            return failure("invalid_options", "unknown metadata limit")
        end
    end
    local max_bytes = options.max_bytes == nil and 1024 * 1024 or options.max_bytes
    local max_rows = options.max_rows == nil and 65536 or options.max_rows
    if
        not integer(field_count, 1024)
        or not integer(max_bytes, 2 ^ 31 - 1)
        or not integer(max_rows, 2 ^ 31 - 1)
    then
        return failure("invalid_options", "metadata field count or limits are invalid")
    end
    if type(data) ~= "string" or data:find("\000", 1, true) then
        return failure("invalid_frame", "tmux metadata must be a NUL-free byte string")
    end
    if #data > max_bytes then
        return failure("frame_limit", "metadata exceeds its byte limit")
    end
    if data == "" then
        return {}
    end
    -- tmux 3.4-3.5a adds printer escapes after q; 3.4 also escapes dollars.
    -- q protects literal backslashes, so decode the combined grammar once.
    local prefix, dialect
    if data:sub(1, #marker) == marker then
        prefix, dialect = marker, "raw"
    elseif data:sub(1, 9) == "LQ1\\r\\$a;" then
        prefix, dialect = "LQ1\\r\\$a;", "dollar"
    elseif data:sub(1, 8) == "LQ1\\r$a;" then
        prefix, dialect = "LQ1\\r$a;", "vis"
    else
        return failure("invalid_frame", "metadata row has an invalid dialect marker")
    end
    local rows, row = {}, {}
    local offset, start = #prefix + 1, #prefix + 1
    if offset > #data then
        return failure("invalid_frame", "metadata ends after its dialect marker", offset)
    end
    while offset <= #data do
        local found = data:find("[\\;]", offset)
        if not found then
            return failure("invalid_frame", "metadata ends before its field separator", offset)
        end
        if data:sub(found, found) == "\\" then
            if found == #data then
                return failure("invalid_frame", "metadata ends inside an escape", found)
            end
            offset = found + 2
        else
            local value, err = decode_field(data, start, found - 1, dialect)
            if value == nil then
                return nil, err
            end
            row[#row + 1] = value
            offset, start = found + 1, found + 1
            if #row == field_count then
                if data:sub(offset, offset + 1) ~= ".\n" then
                    return failure(
                        "invalid_frame",
                        "metadata row has an invalid terminator",
                        offset
                    )
                end
                if #rows >= max_rows then
                    return failure("frame_limit", "metadata exceeds its row limit", offset)
                end
                rows[#rows + 1], row = row, {}
                offset, start = offset + 2, offset + 2
                if offset <= #data then
                    if data:sub(offset, offset + #prefix - 1) ~= prefix then
                        return failure(
                            "invalid_frame",
                            "metadata row has a mixed or invalid dialect marker",
                            offset
                        )
                    end
                    offset, start = offset + #prefix, offset + #prefix
                    if offset > #data then
                        return failure(
                            "invalid_frame",
                            "metadata ends after its dialect marker",
                            offset
                        )
                    end
                end
            end
        end
    end
    if #row ~= 0 or start ~= #data + 1 then
        return failure("invalid_frame", "metadata ends inside a row", start)
    end
    return rows
end

return M
