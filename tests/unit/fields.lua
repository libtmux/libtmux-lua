local test = require("luaunit")
local query = require("libtmux.query")
local tests = {}

---@generic T
---@param value T?
---@param err? table
---@return T
local function must(value, err)
    if value == nil then
        error(err, 0)
    end
    return value
end

local function fields()
    local ok, module = pcall(require, "libtmux._internal.fields")
    test.assertTrue(ok, "generated field catalog is missing")
    return module
end

function tests.test_all_entity_schemas_keep_window_link_context_separate()
    local catalog = fields()
    test.assertEquals(catalog.kinds(), {
        "server",
        "session",
        "window",
        "window_link",
        "pane",
        "client",
        "buffer",
    })
    for _, kind in ipairs(catalog.kinds()) do
        local schema, err = catalog.schema(kind, "3.3a")
        test.assertNil(err)
        test.assertNotNil(query.compile(schema, {}))
    end
    local window = must(catalog.schema("window", "3.7c"))
    test.assertNil(window.fields.index)
    test.assertNil(window.fields.active)
    test.assertNil(window.fields.session_id)
    local link = must(catalog.schema("window_link", "3.7c"))
    test.assertEquals(link.fields.session_id.type, "string")
    test.assertEquals(link.fields.window_id.type, "string")
    test.assertEquals(link.fields.index.type, "number")
    test.assertEquals(link.fields.active.type, "boolean")
    test.assertNil(catalog.schema("pane", "3.7c").fields.session_id)
end

function tests.test_every_cataloged_field_is_available_from_the_floor()
    local catalog = fields()
    test.assertEquals(catalog.support_floor, "3.3a")
    for _, kind in ipairs(catalog.kinds()) do
        for name, field in pairs(must(catalog.schema(kind, "3.3a")).fields) do
            test.assertTrue(field.supported, kind .. "." .. name)
        end
    end
    local pane = must(catalog.schema("pane", "3.3a"))
    test.assertNotNil(query.compile(pane, { dead_signal = { is_null = true } }))
end

function tests.test_release_admission_orders_patch_letters_and_refuses_development_builds()
    local catalog = fields()
    for _, version in ipairs({ "3.3a", "3.3b", "3.4", "3.7c", "3.7d", "3.8", "3.10", "4.0" }) do
        test.assertNotNil(catalog.schema("session", version), version)
    end
    for _, version in ipairs({ "3.2a", "3.3", "3.2", "3.0", "2.9a", "3.1c" }) do
        local value, err = catalog.schema("session", version)
        test.assertNil(value, version)
        test.assertEquals(err and err.code, "unsupported_version", version)
        test.assertStrContains(err.message, "3.3a or newer")
    end
    -- A development build ranks below its release, so none is admitted.
    for _, version in ipairs({
        "next-3.9",
        "next-3.3a",
        "next-3.4",
        "3.8-rc",
        "3.8-rc2",
        "3.3a-rc1",
        "master",
        "3.3a ",
        "3.3A",
        "",
    }) do
        local value, err = catalog.schema("session", version)
        test.assertNil(value, version)
        test.assertEquals(err and err.code, "unsupported_version", version)
        test.assertStrContains(err.message, "prerelease builds are not admitted")
    end
end

function tests.test_nullable_and_string_fields_preserve_tmux_meanings()
    local catalog = fields()
    local pane = must(catalog.schema("pane", "3.7c"))
    test.assertEquals(pane.fields.id.type, "string")
    test.assertTrue(pane.fields.current_path.nullable)
    test.assertTrue(pane.fields.dead_status.nullable)
    test.assertFalse(pane.fields.title.nullable)
    test.assertEquals(pane.fields.mode_count.type, "number")
    local rows = query.select({
        { id = "%1", active = false, title = "", current_path = query.NULL },
        { id = "%2", active = true, title = "title", current_path = "/tmp" },
    }, pane)
    test.assertEquals(#rows:where({ active = false, title = "", current_path = query.NULL }), 1)
    local client = must(catalog.catalog("client"))
    test.assertEquals(client.session_name.format, "client_session")
    test.assertNil(client.session_id)
    test.assertTrue(client.width.nullable)
    test.assertEquals(catalog.catalog("window_link").active.source_scope, "winlink")
end

function tests.test_catalog_and_schema_results_are_copies()
    local catalog = fields()
    local first = must(catalog.catalog("pane"))
    first.id.type = "boolean"
    local source_line = first.id.lines.floor
    first.id.lines.floor = 0
    test.assertEquals(catalog.catalog("pane").id.type, "string")
    test.assertEquals(catalog.catalog("pane").id.symbol, "format_cb_pane_id")
    test.assertEquals(catalog.catalog("pane").id.lines.floor, source_line)
    local schema = must(catalog.schema("pane", "3.3a"))
    schema.fields.dead_signal.supported = false
    test.assertTrue(catalog.schema("pane", "3.3a").fields.dead_signal.supported)
    local kinds = catalog.kinds()
    kinds[1] = "mutated"
    test.assertEquals(catalog.kinds()[1], "server")
end

function tests.test_invalid_entities_and_unverified_version_syntax_are_rejected()
    local catalog = fields()
    local value, err = catalog.schema("unknown", "3.7c")
    test.assertNil(value)
    test.assertEquals(err and err.code, "invalid_entity")
    for _, version in ipairs({ "", "tmux 3.7c", "next-3.8", "3.7-rc", "3.2", "2.9a" }) do
        value, err = catalog.schema("pane", version)
        test.assertNil(value)
        test.assertEquals(err and err.code, "unsupported_version")
    end
    value, err = catalog.schema("pane", nil)
    test.assertNil(value)
    test.assertEquals(err and err.code, "unsupported_version")
end

return tests
