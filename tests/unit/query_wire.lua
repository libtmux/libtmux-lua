local t = require("luaunit")
local query = require("libtmux.query")
local json = require("lunajson")
local M = {}
local child = { fields = { name = { type = "string" } } }
local schema = {
    fields = {
        active = { type = "boolean" },
        size = { type = "number" },
        title = { type = "string", nullable = true },
    },
    relations = {
        children = { cardinality = "many", schema = child },
        parent = { cardinality = "one", schema = child, nullable = true },
    },
}

local function available()
    t.assertEquals(type(query.encode_json), "function", "query JSON encoder is missing")
    t.assertEquals(type(query.decode_json), "function", "query JSON decoder is missing")
end

local function wire(criteria)
    return '{"version":"libtmux.where/v1","where":' .. criteria .. "}"
end

local function rejected(text, code, selected_codec)
    local value, err = query.decode_json(schema, text, selected_codec or json)
    t.assertNil(value)
    t.assertEquals(assert(err).code, code)
end

function M.test_roundtrip_preserves_null_false_and_schema_positioned_empty_containers()
    available()
    local criteria = {
        AND = {},
        OR = {},
        NOT = {},
        active = false,
        title = { one_of = { query.NULL, "", "λ\000雪" }, none_of = {} },
        children = { every = {} },
        parent = { is = query.NULL, is_not = {} },
    }
    local encoded, err = query.encode_json(schema, criteria, json)
    t.assertNil(err)
    assert(encoded)
    t.assertStrContains(encoded, '"AND":[]')
    t.assertStrContains(encoded, '"OR":[]')
    t.assertStrContains(encoded, '"NOT":{}')
    t.assertStrContains(encoded, '"none_of":[]')
    t.assertStrContains(encoded, '"every":{}')
    local decoded = assert(query.decode_json(schema, encoded, json))
    ---@cast decoded table<string, any>
    t.assertEquals(decoded, criteria)
    t.assertIs(decoded.title.one_of[1], query.NULL)
    t.assertIs(decoded.parent.is, query.NULL)
    t.assertFalse(decoded.active)
    t.assertNil(rawget(criteria.AND, 0))
    t.assertNil(rawget(criteria.title.none_of, 0))
    t.assertEquals(assert(query.decode_json(schema, wire("{}"), json)), {})
end

function M.test_entire_grammar_validates_before_codec_encoding_or_empty_query_evaluation()
    available()
    local calls = 0
    local codec = {
        newparser = json.newparser,
        encode = function()
            calls = calls + 1
            return "{}"
        end,
    }
    for _, criteria in ipairs({
        { OR = { {}, { unknown = 1 } } },
        { active = { contains = "x" } },
        { parent = { some = {} } },
        { children = { every = query.NULL } },
    }) do
        local value, err = query.encode_json(schema, criteria, codec)
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_criteria")
    end
    t.assertEquals(calls, 0)
    rejected(wire('{"OR":[{}, {"unknown":1}]}'), "invalid_criteria")
end

function M.test_version_envelope_and_json_container_types_are_not_ambiguous()
    available()
    for _, text in ipairs({
        "{}",
        '{"version":"libtmux.where/v1"}',
        '{"version":"libtmux.where/v1","where":{},"extra":false}',
        wire("[]"),
        wire('{"AND":{}}'),
        wire('{"NOT":[]}'),
        wire('{"title":{"one_of":{}}}'),
        wire('{"children":{"some":[]}}'),
    }) do
        rejected(text, "invalid_wire")
    end
    rejected('{"version":"libtmux.where/v2","where":{}}', "unsupported_wire_version")
end

function M.test_duplicate_keys_malformed_unicode_and_trailing_data_are_rejected()
    available()
    for _, text in ipairs({
        wire('{"active":true,"active":false}'),
        wire('{"active":true,"\\u0061ctive":false}'),
        wire("{}") .. " false",
        wire('{"title":"' .. string.char(255) .. '"}'),
        wire('{"title":"' .. string.char(192, 128) .. '"}'),
        wire('{"title":"' .. string.char(237, 160, 128) .. '"}'),
        wire('{"title":"\\ud800"}'),
        wire('{"title":"\\udc00"}'),
        wire('{"size":01}'),
    }) do
        rejected(text, "invalid_json")
    end
    local value, err = query.encode_json(schema, { title = string.char(255) }, json)
    t.assertNil(value)
    t.assertEquals(assert(err).code, "invalid_json")
    local decoded = assert(query.decode_json(schema, wire('{"title":"\\ud83d\\ude00"}'), json))
    ---@cast decoded table<string, any>
    t.assertEquals(decoded.title, string.char(240, 159, 152, 128))
end

function M.test_wire_numbers_have_portable_finite_range_and_do_not_underflow_to_zero()
    available()
    for _, number in ipairs({ "1e999", "1e-999", "9007199254740992", "-9007199254740992" }) do
        rejected(wire('{"size":' .. number .. "}"), "invalid_json")
    end
    for _, number in ipairs({ math.huge, -math.huge, 0 / 0, 9007199254740992 }) do
        local value, err = query.encode_json(schema, { size = number }, json)
        t.assertNil(value)
        t.assertNotNil(err)
    end
    for _, number in ipairs({ -9007199254740991, 9007199254740991, 0, 1.25, 1e-300 }) do
        local encoded = assert(query.encode_json(schema, { size = number }, json))
        local decoded = assert(query.decode_json(schema, encoded, json))
        ---@cast decoded table<string, any>
        t.assertEquals(decoded.size, number)
    end
    local decoded = assert(query.decode_json(schema, wire('{"size":0e999}'), json))
    ---@cast decoded table<string, any>
    t.assertEquals(decoded.size, 0)
end

function M.test_wire_limits_stop_input_before_parser_and_trees_during_sax()
    available()
    local calls = 0
    local codec = {
        encode = json.encode,
        newparser = function()
            calls = calls + 1
            error("oversized input reached parser")
        end,
    }
    rejected(string.rep(" ", 524289), "query_limit", codec)
    t.assertEquals(calls, 0)
    rejected(wire(string.rep('{"NOT":', 33) .. "{}" .. string.rep("}", 33)), "query_limit")
    rejected(wire('{"AND":[' .. string.rep("{},", 4096) .. "{}]}"), "query_limit")
    rejected(wire('{"title":"' .. string.rep("a", 65537) .. '"}'), "query_limit")
    rejected(wire('{"size":{"one_of":[' .. string.rep("0,", 1024) .. "0]}}"), "query_limit")
end

function M.test_injected_codec_errors_are_data_and_only_private_copies_receive_array_tags()
    available()
    local criteria = { active = false, AND = {} }
    local before = { fields = schema.fields, relations = schema.relations }
    local codec = {
        newparser = json.newparser,
        encode = function(value, null)
            t.assertEquals(value.where.AND[0], 0)
            value.where.active = true
            return json.encode(value, null)
        end,
    }
    assert(query.encode_json(schema, criteria, codec))
    t.assertFalse(criteria.active)
    t.assertEquals(criteria.AND, {})
    t.assertIs(schema.fields, before.fields)
    t.assertIs(schema.relations, before.relations)
    codec.encode = function()
        error({ private = true })
    end
    local value, err = query.encode_json(schema, criteria, codec)
    t.assertNil(value)
    t.assertEquals(assert(err).code, "codec_error")
    codec.newparser = function()
        error({ private = true })
    end
    rejected(wire("{}"), "codec_error", codec)
end

function M.test_codec_is_explicit_and_query_imports_remain_pure()
    available()
    local original_require = _G.require
    local previous_query = package.loaded["libtmux.query"]
    local previous_wire = package.loaded["libtmux._internal.query_wire"]
    package.loaded["libtmux.query"], package.loaded["libtmux._internal.query_wire"] = nil, nil
    rawset(_G, "require", function(name)
        assert(name:match("^libtmux[._]"), "core attempted to load a consumer dependency")
        return original_require(name)
    end)
    local ok, result = pcall(function()
        local pure = original_require("libtmux.query")
        local value, err = pure.encode_json(schema, {}, nil)
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_codec")
        value, err = pure.decode_json(schema, wire("{}"), nil)
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_codec")
    end)
    rawset(_G, "require", original_require)
    package.loaded["libtmux.query"] = previous_query
    package.loaded["libtmux._internal.query_wire"] = previous_wire
    assert(ok, result)
end

return M
