local test = require("luaunit")
local fields = require("generate.fields")
local files = require("support.files")
local json = require("support.json")
local options = require("generate.options")
local render = require("generate.render")
local repo = require("support.repo")
local M = {}

local function committed(path)
    return files.read(repo.root .. "/" .. path)
end

local function mutated(path, change)
    local data = json.read(path)
    change(data)
    return data
end

--- load_catalog reads a path, so a mutation is written to a temporary file first.
local function load_changed(module, path, change)
    local data = mutated(path, change)
    local temporary = os.tmpname()
    files.write(temporary, json.encode(data, 2))
    local ok, failure = pcall(module.load_catalog, temporary)
    os.remove(temporary)
    return ok, failure
end

function M.test_the_committed_field_files_are_what_the_catalog_generates()
    local data = fields.load_catalog()
    test.assertEquals(fields.generate_lua(data), committed("lua/libtmux/_internal/fields.lua"))
    test.assertEquals(fields.generate_docs(data), committed("docs/fields.md"))
end

function M.test_the_committed_option_files_are_what_the_catalog_generates()
    local data = options.load_catalog()
    test.assertEquals(
        options.generate_lua(data),
        committed("lua/libtmux/_internal/options_catalog.lua")
    )
    test.assertEquals(options.generate_docs(data), committed("docs/options-reference.md"))
end

function M.test_a_stale_generated_file_is_named_and_a_current_one_is_not()
    local current = committed("docs/fields.md")
    test.assertEquals(render.settle({ { "docs/fields.md", current } }, true), {})
    test.assertEquals(
        render.settle({ { "docs/fields.md", current .. "x" } }, true),
        { "docs/fields.md" }
    )
    test.assertEquals(
        render.settle({ { "docs/no-such-file.md", "" } }, true),
        { "docs/no-such-file.md" }
    )
end

function M.test_a_catalog_value_becomes_a_lua_literal_in_catalog_order()
    local value = json.decode('{"b":1,"a":[true,null,"x\\u00e9"],"end":{"k-y":"v"},"c":{}}')
    test.assertEquals(
        render.literal(value),
        '{ b = 1, a = { true, nil, "x\\u00e9" }, ["end"] = { ["k-y"] = "v" }, c = {  } }'
    )
end

function M.test_text_wraps_at_the_width_and_after_a_hyphen_between_letters()
    test.assertEquals(
        render.wrap("- `a`: one two three", 12, "  "),
        { "- `a`: one", "  two three" }
    )
    test.assertEquals(render.wrap("aaaa well-known", 10, ""), { "aaaa well-", "known" })
    test.assertEquals(render.wrap("a -b 1-2", 80, ""), { "a -b 1-2" })
    test.assertEquals(render.wrap("", 80, ""), {})
end

function M.test_a_field_catalog_that_breaks_a_reviewed_rule_is_refused()
    local cases = {
        {
            "duplicate record field",
            function(data)
                local list = data.entities[1].fields
                list[#list + 1] = list[1]
            end,
        },
        {
            "unsupported catalog schema",
            function(data)
                data.support_floor = "3.4"
            end,
        },
        {
            "unreviewed availability",
            function(data)
                data.entities[1].fields[1].since = "3.4"
            end,
        },
        {
            "unsupported scalar type",
            function(data)
                data.entities[1].fields[1].type = "float"
            end,
        },
        {
            "entities out of order",
            function(data)
                data.entities[1], data.entities[2] = data.entities[2], data.entities[1]
            end,
        },
        {
            "unknown native format scope",
            function(data)
                data.entities[1].fields[1].source_scope = "nowhere"
            end,
        },
    }
    for _, case in ipairs(cases) do
        local ok = load_changed(fields, fields.CATALOG, case[2])
        test.assertFalse(ok, case[1])
    end
    test.assertTrue(load_changed(fields, fields.CATALOG, function() end))
end

function M.test_an_option_catalog_that_breaks_a_reviewed_rule_is_refused()
    local function first_definition(data)
        return data.definitions[json.keys(data.definitions)[1]]
    end
    local cases = {
        {
            "unreviewed scope",
            function(data)
                first_definition(data).scope_bits = 3
            end,
        },
        {
            "a definition nothing references",
            function(data)
                data.definitions.d9999 = json.decode(
                    '{"name":"zzz","native_type":"flag","scope_bits":1,"scopes":["server"],'
                        .. '"flags_bits":0,"array":false,"hook":false,"style":false,'
                        .. '"separator":null}'
                )
                local keys = json.keys(data.definitions)
                keys[#keys + 1] = "d9999"
            end,
        },
        {
            "a changed release pin",
            function(data)
                data.releases["3.8"].revision = string.rep("0", 40)
            end,
        },
        {
            "an unknown release",
            function(data)
                data.releases["9.9"] = data.releases["3.8"]
                local keys = json.keys(data.releases)
                keys[#keys + 1] = "9.9"
            end,
        },
        {
            "a bad source digest",
            function(data)
                data.releases["3.8"].sources["tmux.h"].sha256 = "abc"
            end,
        },
    }
    for _, case in ipairs(cases) do
        local ok = load_changed(options, options.CATALOG, case[2])
        test.assertFalse(ok, case[1])
    end
    test.assertTrue(load_changed(options, options.CATALOG, function() end))
end

return M
