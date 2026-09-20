local errors = require("libtmux._internal.error")
local M = {}
local MAX_BYTES = 1048576
local versions = {
    ["3.2a"] = true,
    ["3.3"] = true,
    ["3.3a"] = true,
    ["3.4"] = true,
    ["3.5"] = true,
    ["3.5a"] = true,
    ["3.6"] = true,
    ["3.6a"] = true,
    ["3.6b"] = true,
    ["3.7"] = true,
    ["3.7a"] = true,
    ["3.7b"] = true,
    ["3.7c"] = true,
}
local controls = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }

local function failure(code, message, offset)
    return nil, errors.new(code, message, { operation = "option.decode", offset = offset or 1 })
end

local function normalize(text, version)
    if type(version) ~= "string" or not versions[version] then
        return failure("unsupported_version", "option printer version is not supported")
    end
    if type(text) ~= "string" then
        return failure("invalid_frame", "option printer value must be a byte string")
    end
    if #text > MAX_BYTES then
        return failure("frame_limit", "option printer value exceeds one MiB")
    end
    local control = text:find("[%z\001-\031\127]")
    if control then
        return failure(
            "invalid_frame",
            "option printer value contains an unescaped control",
            control
        )
    end
    -- 3.4 server_client_print applies VIS_NOSLASH after args_escape. Its
    -- utf8_strvis still adds a slash before variable-like dollars regardless
    -- of VIS_DQ; existing slashes must survive this one-layer reversal.
    if version == "3.4" then
        return (text:gsub("\\(%$[A-Za-z_{])", "%1"))
    end
    return text
end

-- COMMAND options already contain cmd_list_print output, not one quoted
-- argument. Preserve its grammar and escapes; never parse or execute it here.
function M.command_source(text, version)
    return normalize(text, version)
end

function M.decode_string(text, version)
    local value, err = normalize(text, version)
    if value == nil then
        return nil, err
    end
    if value == "" then
        return failure("invalid_frame", "option string has no token")
    end
    local first = value:sub(1, 1)
    local quote = (first == '"' or first == "'") and first or nil
    local offset, start = quote and 2 or 1, quote and 2 or 1
    local parts, chunks = {}, {}
    local function append(part)
        if part ~= "" then
            parts[#parts + 1] = part
            if #parts == 128 then
                chunks[#chunks + 1], parts = table.concat(parts), {}
            end
        end
    end
    local function finish()
        chunks[#chunks + 1] = table.concat(parts)
        return table.concat(chunks)
    end
    while offset <= #value do
        local found = value:find("[\\'\" ]", offset)
        if not found then
            append(value:sub(offset))
            offset = #value + 1
            break
        end
        append(value:sub(offset, found - 1))
        local byte = value:sub(found, found)
        if byte == quote then
            if found ~= #value then
                return failure("invalid_frame", "option string has trailing text", found + 1)
            end
            return finish()
        elseif byte ~= "\\" then
            if not quote then
                return failure(
                    "invalid_frame",
                    "option string contains an unquoted delimiter",
                    found
                )
            end
            append(byte)
            offset = found + 1
        else
            local escaped = value:sub(found + 1, found + 1)
            offset = found + 2
            if controls[escaped] then
                append(controls[escaped])
            elseif escaped == "\\" or escaped == '"' or escaped == "$" then
                append(escaped)
            elseif escaped:match("^[0-7]$") then
                local digits = value:sub(found + 1, found + 3)
                local number = digits:match("^[0-7][0-7][0-7]$") and tonumber(digits, 8)
                if not number or number == 0 or number > 255 then
                    return failure(
                        "invalid_frame",
                        "option string has an invalid octal escape",
                        found
                    )
                end
                append(string.char(number))
                offset = found + 4
            elseif escaped == "~" and found == start and quote ~= "'" then
                append(escaped)
            elseif #value == 2 and escaped ~= "" and ("#';{}%~"):find(escaped, 1, true) then
                append(escaped)
            else
                return failure("invalid_frame", "option string has an unknown escape", found)
            end
        end
    end
    if quote then
        return failure("invalid_frame", "option string has no closing quote", offset)
    end
    return finish()
end

return M
