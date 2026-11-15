-- Tie README examples, commands and source links to files the gates exercise.
local files = require("support.files")
local fs = require("support.fs")
local json = require("support.json")

local M = {}

M.LOGO_ALT = "libtmux for Lua"
-- One list item or paragraph reads in about three lines of an 80-column terminal.
M.PROSE_LIMIT = 240

local LOGO_HEAD = '<!-- libtmux-logo -->\n<div align="center">\n  <picture>\n'
    .. '    <source srcset="assets/logo.svg" type="image/svg+xml">\n'
    .. '    <img src="assets/logo.png" width="128" height="128" alt="'
local LOGO_TAIL = '">\n  </picture>\n</div>\n<!-- /libtmux-logo -->\n\n<div align="center">\n\n# '
local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local SOURCE_LINK = "https://github%.com/libtmux/libtmux%-lua/"

local function lines_of(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

---@param root string
---@return string[]
function M.readmes(root)
    local found = {}
    for _, relative in ipairs({ "README.md", "lua/libtmux/README.md" }) do
        if fs.is_file(root .. "/" .. relative) then
            found[#found + 1] = relative
        end
    end
    return found
end

local function big_endian(text, first)
    local a, b, c, d = text:byte(first, first + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Requires the centered logo block and the library's art beside the README.
local function check_logo(root, relative, text, art, fail)
    if text:sub(1, #LOGO_HEAD) ~= LOGO_HEAD then
        fail("must open with the centered logo block, then a centered title")
    end
    local alt_end = text:find('"', #LOGO_HEAD + 1, true)
    local alt = text:sub(#LOGO_HEAD + 1, alt_end - 1)
    if text:sub(alt_end, alt_end + #LOGO_TAIL - 1) ~= LOGO_TAIL then
        fail("must open with the centered logo block, then a centered title")
    end
    if alt ~= M.LOGO_ALT then
        fail('logo alt text must be "' .. M.LOGO_ALT .. '"')
    end
    local base = root .. "/" .. (relative:match("^(.*)/[^/]+$") or ".")
    local svg = fs.is_file(base .. "/assets/logo.svg") and files.read(base .. "/assets/logo.svg")
        or ""
    if not svg:find("<svg", 1, true) then
        fail("assets/logo.svg is missing or is not SVG")
    end
    local png = fs.is_file(base .. "/assets/logo.png")
            and files.read(base .. "/assets/logo.png"):sub(1, 24)
        or ""
    if
        png:sub(1, 8) ~= PNG_SIGNATURE
        or png:sub(13, 16) ~= "IHDR"
        or #png < 24
        or big_endian(png, 17) ~= 512
        or big_endian(png, 21) ~= 512
    then
        fail("assets/logo.png is missing or is not a 512 x 512 PNG")
    end
    -- One product, one artwork: every README carries the same art.
    if art[M.LOGO_ALT] == nil then
        art[M.LOGO_ALT] = svg
    elseif art[M.LOGO_ALT] ~= svg then
        fail('logo art differs from the other "' .. M.LOGO_ALT .. '" README')
    end
end

--- The text with every fenced block removed, and the blocks themselves as { info, body }.
local function split_fences(text)
    local kept, blocks, fence = {}, {}, nil
    for _, line in ipairs(lines_of(text)) do
        if fence == nil and line:match("^```") then
            fence = { info = line:sub(4), body = {} }
        elseif fence and line:match("^```[ \t]*$") then
            blocks[#blocks + 1] = { fence.info, table.concat(fence.body, "\n") .. "\n" }
            fence = nil
        elseif fence then
            table.insert(fence.body, line)
        else
            kept[#kept + 1] = line
        end
    end
    return table.concat(kept, "\n"), blocks
end

--- Each marked Lua block: `{ kind, path, body }` for `<!-- example: path -->` and `<!-- excerpt:
--- path -->` comments, in document order.
local function marked_blocks(text)
    local found, position = {}, 1
    while true do
        local first, last, kind, path = text:find("<!%-%- (%a+): (%S+) %-%->\n\n```lua\n", position)
        if not first then
            return found
        end
        local close = text:find("```", last + 1, true)
        if not close then
            return found
        end
        if kind == "example" or kind == "excerpt" then
            found[#found + 1] = { kind, path, text:sub(last + 1, close - 1) }
        end
        position = close + 3
    end
end

--- Strips the indentation shared by the non-blank lines.
local function dedent(lines)
    local cut
    for _, line in ipairs(lines) do
        if line:find("%S") then
            local width = #line:match("^%s*")
            cut = cut and math.min(cut, width) or width
        end
    end
    local result = {}
    for index, line in ipairs(lines) do
        result[index] = line:find("%S") and line:sub((cut or 0) + 1) or ""
    end
    return result
end

--- True when the block is a run of consecutive source lines, up to shared indentation.
function M.is_excerpt(block, source)
    local wanted = dedent(lines_of((block:gsub("\n+$", ""))))
    local lines = lines_of(source)
    for start = 1, #lines - #wanted + 1 do
        local window = dedent({ unpack(lines, start, start + #wanted - 1) })
        if table.concat(window, "\n") == table.concat(wanted, "\n") then
            return true
        end
    end
    return false
end

local function definition(line)
    return line:match("^%[[^%]]+%]:[ \t]+%S+[ \t]*$") ~= nil
end

--- Each paragraph and list item outside code, tables, headings and HTML.
function M.prose_blocks(text)
    local prose = split_fences(text)
    local blocks = {}
    for chunk in (prose .. "\n\n"):gmatch("(.-)\n%s*\n") do
        local lines = lines_of((chunk:gsub("^\n+", ""):gsub("\n+$", "")))
        local first = lines[1] or ""
        local skip = first:find("%S") == nil
            or first:match("^[#|<]")
            or first:sub(1, 12) == "**Contents**"
            or definition(first)
        if not skip then
            local items, current = {}, {}
            for _, line in ipairs(lines) do
                if (line:match("^[%-%*]%s") or line:match("^%d+%.%s")) and #current > 0 then
                    items[#items + 1] = current
                    current = {}
                end
                current[#current + 1] = line
            end
            items[#items + 1] = current
            for _, item in ipairs(items) do
                local parts = {}
                for index, line in ipairs(item) do
                    parts[index] = line:match("^%s*(.-)%s*$")
                end
                blocks[#blocks + 1] = table.concat(parts, " ")
            end
        end
    end
    return blocks
end

--- The text a reader sees: link targets and code ticks removed.
function M.rendered(markdown)
    local text = markdown:gsub("%[([^%]]+)%]%[[^%]]*%]", "%1"):gsub("%[([^%]]+)%]%([^)]*%)", "%1")
    text = text:gsub("`", ""):gsub("%s+", " ")
    return (text:match("^%s*(.-)%s*$"))
end

--- Requires a Quick start first, the closing sections, short prose and defined links.
local function check_structure(text, fail)
    local prose = split_fences(text)
    local headings = {}
    for _, line in ipairs(lines_of(prose)) do
        local level, title = line:match("^(#+)[ \t]+(.-)[ \t]*$")
        if level == "##" then
            headings[#headings + 1] = title
        end
    end
    if headings[1] ~= "Quick start" then
        fail("the first section must be Quick start")
    end
    for _, title in ipairs({ "What it leaves out", "Support and status" }) do
        local present = false
        for _, heading in ipairs(headings) do
            present = present or heading == title
        end
        if not present then
            fail("missing the " .. title .. " section")
        end
    end
    for _, block in ipairs(M.prose_blocks(text)) do
        if #M.rendered(block) > M.PROSE_LIMIT then
            fail(
                ("prose over %d characters, which reads as a wall: %s..."):format(
                    M.PROSE_LIMIT,
                    block:sub(1, 48)
                )
            )
        end
    end
    local defined = {}
    for _, line in ipairs(lines_of(text)) do
        local label = line:match("^%[([^%]]+)%]:[ \t]+%S+[ \t]*$")
        if label then
            defined[label] = true
        end
    end
    for label in prose:gmatch("%[[^%]]+%]%[([^%]]+)%]") do
        if not defined[label] then
            fail("link reference is not defined: [" .. label .. "]")
        end
    end
end

--- A console block as { command, output lines } pairs.
function M.console_steps(block)
    local steps = {}
    for _, line in ipairs(lines_of((block:gsub("\n$", "")))) do
        local last = steps[#steps]
        if line:sub(1, 2) == "$ " then
            steps[#steps + 1] = { line:sub(3), {} }
        elseif last and last[1]:sub(-1) == "\\" and #last[2] == 0 then
            last[1] = last[1]:sub(1, -2):gsub("%s+$", "") .. " " .. line:match("^%s*(.-)%s*$")
        elseif last then
            table.insert(last[2], line)
        end
    end
    return steps
end

local function module_version(root, module)
    local relative = module:gsub("%.", "/")
    for _, candidate in ipairs({
        root .. "/lua/" .. relative .. ".lua",
        root .. "/lua/" .. relative .. "/init.lua",
    }) do
        if fs.is_file(candidate) then
            for _, line in ipairs(lines_of(files.read(candidate))) do
                local version = line:match('^%s*return%s*{%s*_VERSION%s*=%s*"([^"]+)"')
                    or line:match('^%s*_VERSION%s*=%s*"([^"]+)"')
                if version then
                    return version
                end
            end
            return nil
        end
    end
end

local function word_path(text, prefix)
    return text:gmatch("%f[%w_]" .. prefix .. "/[%w_%./%-]*[%w_]")
end

--- Raises an error naming the first README that quotes, runs or links something that differs from
--- the source.
---@param root string
function M.check_readmes(root)
    local manifest_path = root .. "/examples/api/manifest.json"
    local outputs = {}
    if fs.is_file(manifest_path) then
        for _, example in ipairs(json.read(manifest_path).examples) do
            outputs[example.file] = example.stdout
        end
    end
    local art = {}
    for _, relative in ipairs(M.readmes(root)) do
        local text = files.read(root .. "/" .. relative)
        local function fail(message)
            error("Invalid README " .. relative .. ": " .. message, 0)
        end
        check_logo(root, relative, text, art, fail)
        local lua_fences = 0
        for _, line in ipairs(lines_of(text)) do
            lua_fences = lua_fences + (line == "```lua" and 1 or 0)
        end
        local marked = marked_blocks(text)
        if lua_fences ~= #marked then
            fail("a Lua block lacks an example or excerpt marker, so nothing runs it")
        end
        for _, block in ipairs(marked) do
            local kind, path, body = block[1], block[2], block[3]
            if not fs.is_file(root .. "/" .. path) then
                fail(kind .. " source is missing: " .. path)
            end
            local source = files.read(root .. "/" .. path)
            if kind == "example" and body ~= source then
                fail("Lua block differs from " .. path)
            elseif kind == "excerpt" and not M.is_excerpt(body, source) then
                fail("Lua block is not a run of lines from " .. path)
            end
        end
        check_structure(text, fail)
        local _, fences = split_fences(text)
        for _, fence in ipairs(fences) do
            if fence[1] == "console" then
                for _, step in ipairs(M.console_steps(fence[2])) do
                    local command, output = step[1], step[2]
                    for _, prefix in ipairs({ "rockspecs", "examples" }) do
                        for path in word_path(command, prefix) do
                            if
                                not (
                                    fs.is_file(root .. "/" .. path)
                                    or fs.is_directory(root .. "/" .. path)
                                )
                            then
                                fail("command names a missing file: " .. path)
                            end
                        end
                    end
                    local program = command:match("^lua (examples/api/[%w_]+%.lua)$")
                    if program and table.concat(output, "\n") .. "\n" ~= outputs[program] then
                        fail("output differs from the manifest for " .. program)
                    end
                    local printed = command:match('print%(require%("([%w_%.]+)"%)%._VERSION%)')
                    if printed and (#output ~= 1 or output[1] ~= module_version(root, printed)) then
                        fail("printed version differs from " .. printed .. " source")
                    end
                end
            end
        end
        local position = 1
        while true do
            local first, last = text:find(SOURCE_LINK .. "[tb][rl][eo][eb]/master/", position)
            if not first then
                break
            end
            local path = text:match("^[%w_%./%-]+", last + 1) or ""
            local target = root .. "/" .. path:gsub("%.+$", "")
            if not (fs.is_file(target) or fs.is_directory(target)) then
                fail("source link names a missing path: " .. path)
            end
            position = last + 1
        end
    end
end

return M
