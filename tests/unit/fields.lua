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
        local schema, err = catalog.schema(kind, "3.2a")
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

function tests.test_version_gates_preserve_known_unsupported_fields()
    local catalog = fields()
    local floor = must(catalog.schema("pane", "3.2a"))
    test.assertFalse(floor.fields.dead_signal.supported)
    test.assertFalse(floor.fields.dead_time.supported)
    test.assertTrue(floor.fields.dead_status.supported)
    local compiled, err = query.compile(floor, { dead_signal = { is_null = true } })
    test.assertNil(compiled)
    test.assertEquals(err and err.code, "unsupported_field")
    local next_version = must(catalog.schema("pane", "3.3"))
    test.assertTrue(next_version.fields.dead_signal.supported)
    test.assertTrue(next_version.fields.dead_time.supported)
    test.assertNotNil(query.compile(next_version, { dead_signal = { is_null = true } }))
    for _, version in ipairs({ "3.2a", "3.2b", "3.3", "3.7c", "3.7d", "3.10" }) do
        test.assertNotNil(catalog.schema("session", version))
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
    local schema = must(catalog.schema("pane", "3.2a"))
    schema.fields.dead_signal.supported = true
    test.assertFalse(catalog.schema("pane", "3.2a").fields.dead_signal.supported)
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
