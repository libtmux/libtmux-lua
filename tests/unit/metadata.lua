local t = require("luaunit")
local query = require("libtmux.query")
local available, metadata = pcall(require, "libtmux._internal.metadata")
local M = {}

local function projection(names, version, kind)
    t.assertTrue(available, "typed metadata projection is not implemented")
    local result, err = metadata.projection(kind or "pane", version or "3.7c", names)
    t.assertNotNil(result, tostring(err))
    return result
end

local function frame(values)
    local parts = {}
    for index, value in ipairs(values) do
        parts[index] = value:gsub("([\\;])", "\\%1")
    end
    return "LQ1\r$a;" .. table.concat(parts, ";") .. ";.\n"
end

function M.test_projection_copies_names_and_returns_full_fresh_schema()
    local names = { "id", "active" }
    local selected = projection(names, "3.2a")
    names[1] = "width"
    selected.names, selected.format, selected.schema = { "width" }, "injected", {}
    t.assertEquals(metadata.format(selected), "LQ1\r$a;#{q:pane_id};#{q:pane_active};.")
    local schema = assert(metadata.schema(selected))
    t.assertEquals(schema.fields.id.type, "string")
    t.assertEquals(schema.fields.width.type, "number")
    t.assertFalse(schema.fields.dead_signal.supported)
    schema.fields.id.type = "number"
    schema.fields.width = nil
    local fresh = assert(metadata.schema(selected))
    t.assertEquals(fresh.fields.id.type, "string")
    t.assertEquals(fresh.fields.width.type, "number")
    local rows = assert(metadata.decode(frame({ "%01", "1" }), selected))
    t.assertEquals(rows[1], { id = "%01", active = true })
    local matched, err = pcall(query.where, rows, { width = 80 }, fresh)
    t.assertFalse(matched)
    t.assertEquals(rawget(err, "code"), "unloaded_field")
    local compiled, unknown = query.compile(fresh, { no_such_field = 1 })
    t.assertNil(compiled)
    t.assertEquals(unknown and unknown.code, "invalid_criteria")
end

function M.test_typed_rows_preserve_bytes_false_and_loaded_nulls()
    local selected = projection({ "id", "index", "active", "title", "current_path", "dead_status" })
    local title = "semi;slash\\\255\n"
    local rows = assert(
        metadata.decode(
            frame({ "%7", "2", "1", "", "", "" })
                .. frame({ "%8", "0", "0", title, "/working", "17" }),
            selected
        )
    )
    t.assertEquals(rows[1], {
        id = "%7",
        index = 2,
        active = true,
        title = "",
        current_path = query.NULL,
        dead_status = query.NULL,
    })
    t.assertIs(rows[1].current_path, query.NULL)
    t.assertEquals(rows[2], {
        id = "%8",
        index = 0,
        active = false,
        title = title,
        current_path = "/working",
        dead_status = 17,
    })
    t.assertNil(rows[1].width)
end

function M.test_decimal_integers_preserve_safe_range_and_reject_other_syntax()
    local selected = projection({ "index" })
    for _, value in ipairs({
        "0",
        "-0",
        "42",
        "-7",
        "00042",
        "9007199254740991",
        "-9007199254740991",
    }) do
        local rows = assert(metadata.decode(frame({ value }), selected))
        t.assertEquals(rows[1].index, tonumber(value))
    end
    for _, value in ipairs({
        "",
        "+1",
        "1.5",
        "1e3",
        "0x10",
        " 1",
        "1 ",
        "nan",
        "inf",
        "9007199254740992",
        "-9007199254740992",
        "999999999999999999999999999999",
        "-9223372036854775808",
    }) do
        local rows, err = metadata.decode(frame({ value }), selected)
        t.assertNil(rows)
        assert(err)
        t.assertEquals(err.code, "invalid_metadata")
        t.assertEquals(err.row, 1)
        t.assertEquals(err.field, "index")
        t.assertEquals(err.expected, "number")
    end
end

function M.test_booleans_accept_only_zero_and_one()
    local selected = projection({ "active" })
    for _, value in ipairs({ "", "false", "true", "2", "01", "-1" }) do
        local rows, err = metadata.decode(frame({ value }), selected)
        t.assertNil(rows)
        assert(err)
        t.assertEquals(err.code, "invalid_metadata")
        t.assertEquals(err.field, "active")
        t.assertEquals(err.expected, "boolean")
    end
end

function M.test_projection_rejects_invalid_unknown_and_unsupported_fields()
    t.assertTrue(available, "typed metadata projection is not implemented")
    local too_many = {}
    for index = 1, 1025 do
        too_many[index] = "id"
    end
    local cases = { {}, false, { "id", "id" }, { [2] = "id" }, { "id", false }, too_many }
    local touched = false
    cases[#cases + 1] = setmetatable({ "id" }, {
        __len = function()
            touched = true
            error("projection metamethod must not run")
        end,
    })
    for _, names in ipairs(cases) do
        local result, err = metadata.projection("pane", "3.2a", names)
        t.assertNil(result)
        t.assertEquals(err and err.code, "invalid_projection")
    end
    t.assertFalse(touched)
    for _, name in ipairs({ "no_such_field", "#{pane_id}", "id};#{version}" }) do
        local result, err = metadata.projection("pane", "3.2a", { name })
        t.assertNil(result)
        t.assertEquals(err and err.code, "unknown_field")
    end
    local result, err = metadata.projection("pane", "3.2a", { "dead_signal" })
    t.assertNil(result)
    t.assertEquals(err and err.code, "unsupported_field")
end

function M.test_decode_propagates_framing_and_limits_and_rejects_forged_projection()
    local selected = projection({ "id" })
    local rows, err = metadata.decode("%7;", selected)
    t.assertNil(rows)
    t.assertEquals(err and err.code, "invalid_frame")
    rows, err = metadata.decode(frame({ "%7" }) .. frame({ "%8" }), selected, { max_rows = 1 })
    t.assertNil(rows)
    t.assertEquals(err and err.code, "frame_limit")
    for _, operation in ipairs({ metadata.format, metadata.schema }) do
        local result, failure = operation({})
        t.assertNil(result)
        t.assertEquals(failure and failure.code, "invalid_projection")
    end
    rows, err = metadata.decode("%7;.\n", {})
    t.assertNil(rows)
    t.assertEquals(err and err.code, "invalid_projection")
end

return M
