local test = require("luaunit")
local export = require("docs.export")
local files = require("support.files")
local json = require("support.json")
local repo = require("support.repo")
local M = {}

local function read(relative)
    return files.read(repo.root .. "/" .. relative)
end

--- The members the Server overview names and the ones the class declares.
local function server_members(source)
    local lines = {}
    for line in (source .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    local declaration
    for index, line in ipairs(lines) do
        if line == "---@class libtmux.Server" then
            declaration = index
        end
    end
    local start = declaration
    while lines[start - 1]:sub(1, 3) == "---" and lines[start - 1]:sub(1, 4) ~= "---@" do
        start = start - 1
    end
    local listed, declared = {}, {}
    for member in table.concat(lines, "\n", start, declaration - 1):gmatch("`Server:([%w_]+)`") do
        listed[member] = true
    end
    for index = declaration + 1, #lines do
        if lines[index]:sub(1, 3) ~= "---" then
            break
        end
        local member = lines[index]:match("^%-%-%-@field ([%w_]+)%f[^%w_]")
        if member then
            declared[member] = true
        end
    end
    return listed, declared
end

local function difference(left, right)
    local names = {}
    for name in pairs(left) do
        if not right[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

function M.test_export_annotations_are_isolated_from_runtime_modules()
    for _, row in ipairs(export.ANNOTATED) do
        local source = read("lua/" .. row[1])
        test.assertNil(source:find("---@class " .. row[2], 1, true), row[1])
    end
    test.assertEquals(#export.ANNOTATED, 3)
end

function M.test_the_export_is_deterministic_json()
    local value = json.decode('{"b":[2,{"z":1,"a":2}],"a":"x"}')
    test.assertEquals(json.encode(value, nil, true), '{"a":"x","b":[2,{"a":2,"z":1}]}')
    test.assertEquals(json.encode(value), '{"b":[2,{"z":1,"a":2}],"a":"x"}')
end

function M.test_every_handle_class_is_a_required_export()
    local expected = {}
    for _, name in ipairs(export.EXPECTED_TYPES) do
        expected[name] = true
    end
    local classes = {}
    local entity = read("lua/libtmux/_internal/entity.lua")
    for name in entity:gmatch("\n%-%-%-@class (libtmux%.[%w_]+)") do
        classes[#classes + 1] = name
    end
    test.assertTrue(expected["libtmux.Session"])
    for _, name in ipairs(classes) do
        test.assertTrue(expected[name], name .. " is not a required export")
    end
end

function M.test_declarations_drop_private_fields_and_sort_by_name_and_position()
    local raw = json.decode([==[[
        {"name":"libtmux.B","fields":[{"name":"_hidden"},{"name":"z","start":[3,0]},
            {"name":"a","start":[1,0],"DOC":"x"}]},
        {"name":"other.C"},
        {"name":"libtmux.A","defines":[{"name":"d","file":"lua/x.lua"}]}]]==])
    local declarations = export.public_declarations(raw)
    test.assertEquals({ declarations[1].name, declarations[2].name }, { "libtmux.A", "libtmux.B" })
    test.assertEquals(#declarations[1].fields, 0)
    local fields = declarations[2].fields
    test.assertEquals({ fields[1].name, fields[2].name }, { "a", "z" })
    test.assertEquals(fields[1].start, { 2, 0 })
    test.assertNil(fields[1].DOC)
    test.assertEquals(declarations[1].defines[1].file, "lua/x.lua")
end

function M.test_the_export_refuses_what_it_must_not_publish()
    local function payload(declarations)
        local all = {}
        for _, name in ipairs(export.EXPECTED_TYPES) do
            all[#all + 1] = { name = name, fields = {}, defines = {} }
        end
        for module, names in pairs(export.EXPECTED_MODULES) do
            local fields = {}
            for _, name in ipairs(names) do
                fields[#fields + 1] = { name = name, file = "lua/libtmux/x.lua" }
            end
            all[#all + 1] = { name = module, fields = fields, defines = {} }
        end
        for _, extra in ipairs(declarations or {}) do
            all[#all + 1] = extra
        end
        return { declarations = all }
    end
    export.validate(payload())
    test.assertErrorMsgContains(
        "invalid declaration source",
        export.validate,
        payload({ { name = "libtmux.X", fields = { { name = "x", file = "lua/tests/y.lua" } } } })
    )
    test.assertErrorMsgContains(
        "invalid declaration source",
        export.validate,
        payload({ { name = "libtmux.X", fields = { { name = "x", file = "elsewhere.lua" } } } })
    )
    test.assertErrorMsgContains(
        "private helper exported",
        export.validate,
        payload({ { name = "libtmux.X", defines = { { name = "_p", file = "lua/a.lua" } } } })
    )
    test.assertErrorMsgContains(
        "machine-specific path",
        export.validate,
        payload({
            {
                name = "libtmux.X",
                defines = { { name = "p", file = "lua/a.lua", note = "/home/x/y" } },
            },
        })
    )
    local missing = payload()
    table.remove(missing.declarations, 1)
    test.assertErrorMsgContains("missing public types", export.validate, missing)
    local extra = payload()
    table.insert(
        extra.declarations[#extra.declarations].fields,
        { name = "surprise", file = "lua/a.lua" }
    )
    test.assertErrorMsgContains("public module coverage differs", export.validate, extra)
end

function M.test_the_rock_metadata_and_bundles_come_from_the_checkout()
    local metadata = export.rock_metadata(repo.root)
    test.assertEquals(metadata.name, "libtmux")
    test.assertStrMatches(metadata.version, "%d+%.%d+%.%d+%-%d+")
    test.assertStrMatches(metadata.source_tag, "v%d+%.%d+%.%d+")
    local guides = export.content_files(repo.root, { { "README.md", "" }, { "docs", ".md" } })
    test.assertEquals(guides[1].path, "README.md")
    for index = 2, #guides do
        test.assertTrue(guides[index - 1].path < guides[index].path)
    end
end

function M.test_server_overview_names_exactly_the_class_members()
    local listed, declared = server_members(read("lua/libtmux/_internal/server.lua"))
    test.assertTrue(next(declared) ~= nil)
    test.assertEquals(difference(declared, listed), {})
    test.assertEquals(difference(listed, declared), {})
end

function M.test_server_overview_check_reports_missing_and_invented_members()
    local source = read("lua/libtmux/_internal/server.lua")
    test.assertNotNil(source:find("`Server:batch`", 1, true))
    local listed, declared = server_members((source:gsub("`Server:batch`", "`batch`")))
    test.assertEquals(difference(declared, listed), { "batch" })
    listed, declared =
        server_members((source:gsub("`Server:batch`", "`Server:batch` and `Server:kill_server`")))
    test.assertEquals(difference(listed, declared), { "kill_server" })
end

return M
