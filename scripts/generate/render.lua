-- What the generators share: Lua source for a decoded catalog value, StyLua formatting, comparison
-- with the committed file, and the text wrapping the reference pages use.
local files = require("support.files")
local json = require("support.json")
local repo = require("support.repo")
local shell = require("support.shell")

local M = {}

local RESERVED = {}
for word in
    ([[and break do else elseif end false for function if in local nil not or repeat return then
    true until while]]):gmatch("%a+")
do
    RESERVED[word] = true
end

--- A Lua literal for a decoded JSON value. Objects keep their catalog order and take a bare key
--- when it is an identifier.
---@param value any
---@return string
function M.literal(value)
    if value == nil or value == json.null then
        return "nil"
    elseif type(value) == "boolean" then
        return tostring(value)
    elseif type(value) == "string" then
        return json.encode(value)
    elseif type(value) == "number" then
        return ("%.14g"):format(value)
    end
    local entries = {}
    if json.is_object(value) then
        for _, key in ipairs(json.keys(value)) do
            local name = (key:match("^[a-z_][a-z0-9_]*$") and not RESERVED[key]) and key
                or "[" .. M.literal(key) .. "]"
            entries[#entries + 1] = name .. " = " .. M.literal(value[key])
        end
    else
        for index, item in ipairs(value) do
            entries[index] = M.literal(item)
        end
    end
    return "{ " .. table.concat(entries, ", ") .. " }"
end

--- Source formatted by the pinned StyLua with the repository's settings.
---@param source string
---@return string
function M.format(source)
    local path = os.tmpname()
    files.write(path, source)
    local code, output = shell.run({ "stylua", "--syntax", "Lua51", "-" }, {
        cwd = repo.root,
        stdin = path,
    })
    os.remove(path)
    if code ~= 0 then
        error("stylua failed (" .. code .. "): " .. output, 0)
    end
    return output
end

--- Writes each generated file, or with `check` reports the ones that differ. Returns the stale
--- paths, relative to the repository.
---@param outputs { [1]: string, [2]: string }[] pairs of repository-relative path and content
---@param check boolean
---@return string[] stale
function M.settle(outputs, check)
    local stale = {}
    for _, output in ipairs(outputs) do
        local path, content = repo.root .. "/" .. output[1], output[2]
        if check then
            local handle = io.open(path, "rb")
            local current = handle and handle:read("*a")
            if handle then
                handle:close()
            end
            if current ~= content then
                stale[#stale + 1] = output[1]
            end
        else
            files.write(path, content)
        end
    end
    return stale
end

-- textwrap.wrap splits a word after a hyphen that sits between two letters, so a reference line
-- may break there.
local function chunks(text)
    local list = {}
    for word in text:gmatch("%S+") do
        local start = 1
        for position = 2, #word - 1 do
            if
                word:sub(position, position) == "-"
                and word:sub(position - 1, position - 1):match("%a")
                and word:sub(position + 1, position + 1):match("%a")
            then
                list[#list + 1] = word:sub(start, position)
                start = position + 1
            end
        end
        list[#list + 1] = word:sub(start)
        list[#list + 1] = false
    end
    return list
end

--- Wraps `text`, which holds no hard-to-split words, to `width` columns: lines break between words
--- or after a hyphen between letters, and every line after the first starts with `indent`.
---@param text string
---@param width integer
---@param indent string
---@return string[]
function M.wrap(text, width, indent)
    local lines, line = {}, ""
    local function push()
        lines[#lines + 1] = line
        line = indent
    end
    local pending, first = "", true
    local parts = chunks(text)
    for index = 1, #parts do
        local part = parts[index]
        if part == false then
            pending = " "
        else
            local candidate = line .. (line:match("%S") and pending or "") .. part
            if #candidate > width and line:match("%S") then
                push()
                candidate = line .. part
            end
            line, pending, first = candidate, "", false
        end
    end
    if not first then
        lines[#lines + 1] = line
    end
    return lines
end

return M
