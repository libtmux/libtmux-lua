-- Serialize the capability registry to libtmux-capabilities/1 JSON on stdout.
local registry = require("libtmux._internal.support.capabilities")
local fields = require("libtmux._internal.fields")

local function string_json(value)
    return '"'
        .. value:gsub('[%c"\\]', function(char)
            local named = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n" }
            return named[char] or string.format("\\u%04x", char:byte())
        end)
        .. '"'
end

local function list_json(items, render)
    local parts = {}
    for _, item in ipairs(items) do
        parts[#parts + 1] = render(item)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
end

local function commands_json(commands)
    return list_json(commands, function(item)
        local out = '{"command": ' .. string_json(item.command)
        if item.flags and #item.flags > 0 then
            out = out .. ', "flags": ' .. list_json(item.flags, string_json)
        end
        return out .. "}"
    end)
end

-- Keys are written in the order the docs schema declares them.
local function object(pairs_list, indent)
    local lines = {}
    for _, pair in ipairs(pairs_list) do
        lines[#lines + 1] = indent .. "  " .. string_json(pair[1]) .. ": " .. pair[2]
    end
    return "{\n" .. table.concat(lines, ",\n") .. "\n" .. indent .. "}"
end

local function capability_json(entry)
    local body = {
        { "id", string_json(entry.id) },
        { "name", string_json(entry.name) },
        { "summary", string_json(entry.summary) },
        { "since", string_json(entry.since) },
    }
    if #entry.except > 0 then
        body[#body + 1] = { "except", list_json(entry.except, string_json) }
    end
    body[#body + 1] = { "handling", string_json(entry.handling) }
    if entry.error then
        body[#body + 1] = { "error", string_json(entry.error) }
    end
    body[#body + 1] = { "apis", list_json(entry.apis, string_json) }
    body[#body + 1] = { "commands", commands_json(entry.commands) }
    return object(body, "    ")
end

local function workaround_json(entry)
    return object({
        { "id", string_json(entry.id) },
        { "name", string_json(entry.name) },
        { "summary", string_json(entry.summary) },
        { "releases", list_json(entry.releases, string_json) },
        { "handling", string_json(entry.handling) },
        { "apis", list_json(entry.apis, string_json) },
        { "commands", commands_json(entry.commands) },
    }, "    ")
end

local function block(items, render)
    local parts = {}
    for _, item in ipairs(items) do
        parts[#parts + 1] = "    " .. render(item):gsub("^%s+", "")
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n  ]"
end

local text = object({
    { "schema", string_json("libtmux-capabilities/1") },
    { "port", string_json("lua") },
    { "floor", '{"minimum": ' .. string_json(fields.support_floor) .. "}" },
    { "capabilities", block(registry.capabilities, capability_json) },
    { "workarounds", block(registry.workarounds, workaround_json) },
}, "") .. "\n"

-- A caller that passes "render" gets the text back, which is how the unit
-- suite compares it with the committed manifest; the script writes it.
if select(1, ...) == "render" then
    return text
end
io.write(text)
