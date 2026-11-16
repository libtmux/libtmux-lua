local files = require("support.files")
local sax = require("lunajson.sax")

local M = {}

M.null = setmetatable({}, {
    __tostring = function()
        return "null"
    end,
})

-- Lua tables are unordered, so an object carries its key order here: decode records it and
-- `object` sets it. A plain table encodes as an array when it has a sequence part, otherwise as an
-- object with sorted keys, and an empty plain table is `[]`.
local order = setmetatable({}, { __mode = "k" })

function M.object(keys, fields)
    order[fields] = keys
    return fields
end

--- Whether a decoded value is a JSON object, as opposed to an array.
---@param value table
---@return boolean
function M.is_object(value)
    return order[value] ~= nil
end

---@param object table
---@return string[]
function M.keys(object)
    local keys = order[object]
    if keys then
        return keys
    end
    keys = {}
    for key in pairs(object) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

---@param text string
---@return any
function M.decode(text)
    local stack, root = {}, nil
    ---@type string
    local name = ""
    local function add(value)
        local parent = stack[#stack]
        if parent == nil then
            root = value
        elseif order[parent] then
            if parent[name] == nil then
                table.insert(order[parent], name)
            end
            parent[name] = value
        else
            parent[#parent + 1] = value
        end
    end
    local function open(container)
        add(container)
        stack[#stack + 1] = container
    end
    local function close()
        stack[#stack] = nil
    end
    local parser = sax.newparser(text, {
        startobject = function()
            open(M.object({}, {}))
        end,
        startarray = function()
            open({})
        end,
        endobject = close,
        endarray = close,
        key = function(key)
            name = key
        end,
        string = add,
        number = add,
        boolean = add,
        null = function()
            add(M.null)
        end,
    })
    parser.run()
    if parser.read(#text):find("[^ \n\r\t]") then
        error("trailing data after the JSON value", 0)
    end
    return root
end

local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function utf16(sequence)
    local lead = sequence:byte(1)
    local length = lead >= 240 and 4 or lead >= 224 and 3 or 2
    if #sequence ~= length then
        error("invalid UTF-8 in a JSON string", 0)
    end
    local point = lead % 2 ^ (7 - length)
    for index = 2, length do
        point = point * 64 + sequence:byte(index) % 64
    end
    if point < 0x10000 then
        return ("\\u%04x"):format(point)
    end
    point = point - 0x10000
    return ("\\u%04x\\u%04x"):format(0xD800 + math.floor(point / 1024), 0xDC00 + point % 1024)
end

-- Escapes every non-ASCII character as \uXXXX, in surrogate pairs above U+FFFF, so the output is
-- plain ASCII.
local function quote(text)
    local escaped = text:gsub('[%c"\\]', function(char)
        return ESCAPES[char] or ("\\u%04x"):format(char:byte())
    end)
    return '"' .. escaped:gsub("[\192-\247][\128-\191]*", utf16) .. '"'
end

local function number(value)
    if value ~= value or value == math.huge or value == -math.huge then
        error("cannot encode a non-finite number as JSON", 0)
    end
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
        return ("%d"):format(value)
    end
    local text = ("%.14g"):format(value)
    return tonumber(text) == value and text or ("%.17g"):format(value)
end

-- `indent` is the number of spaces per level, or nil for the compact separators "," and ":".
-- `sort_keys` orders every object's keys.
function M.encode(value, indent, sort_keys)
    local function emit(item, level)
        if item == M.null then
            return "null"
        elseif type(item) == "string" then
            return quote(item)
        elseif type(item) == "number" then
            return number(item)
        elseif type(item) ~= "table" then
            return tostring(item)
        end
        local keys = order[item]
        if keys and sort_keys then
            keys = { unpack(keys) }
            table.sort(keys)
        end
        if not keys and next(item) ~= nil and item[1] == nil then
            keys = M.keys(item)
        end
        local inner = indent and ("\n" .. (" "):rep(indent * (level + 1))) or ""
        local parts = {}
        if keys then
            for _, key in ipairs(keys) do
                if item[key] ~= nil then
                    local separator = indent and ": " or ":"
                    parts[#parts + 1] = inner
                        .. quote(key)
                        .. separator
                        .. emit(item[key], level + 1)
                end
            end
        else
            for index = 1, #item do
                parts[index] = inner .. emit(item[index], level + 1)
            end
        end
        local first, last = "[", "]"
        if keys then
            first, last = "{", "}"
        end
        if #parts == 0 then
            return first .. last
        end
        local closing = indent and ("\n" .. (" "):rep(indent * level)) or ""
        return first .. table.concat(parts, ",") .. closing .. last
    end
    return emit(value, 0)
end

---@param path string
---@return any
function M.read(path)
    return M.decode(files.read(path))
end

function M.write(path, value, indent, sort_keys)
    files.write(path, M.encode(value, indent, sort_keys) .. "\n")
end

return M
