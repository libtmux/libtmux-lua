local query = require("libtmux.query")
local lu = require("luaunit")
local tests = {}

---@param value unknown
---@param code string
local function assert_error(value, code)
    assert(type(value) == "table")
    lu.assertEquals(value.code, code)
    lu.assertIsString(value.operation)
    lu.assertIsString(value.message)
    lu.assertIsString(value.path)
    lu.assertIsString(tostring(value))
end

local child = { fields = { name = { type = "string" } } }
local schema = {
    fields = {
        name = { type = "string" },
        active = { type = "boolean" },
        size = { type = "number" },
        title = { type = "string", nullable = true },
    },
    relations = {
        children = { cardinality = "many", schema = child },
        parent = { cardinality = "one", schema = child, nullable = true },
    },
}

function tests.test_selection_preserves_native_order_duplicates_and_sharing()
    local first, second = { name = "first" }, { name = "second" }
    local source = { first, second, first }
    local selected = query.select(source, schema)
    local filtered = selected:filter(function(row)
        return row.name == "first"
    end)
    lu.assertEquals(#selected, 3)
    lu.assertEquals(#filtered, 2)
    lu.assertIs(filtered[1], first)
    lu.assertIs(filtered[2], first)
    lu.assertIs(source[2], second)
    local count = 0
    for index, row in ipairs(filtered) do
        count = count + 1
        lu.assertIs(row, first)
        lu.assertEquals(index, count)
    end
    lu.assertEquals(count, 2)
    local plain = filtered:to_table()
    lu.assertNil(getmetatable(plain))
    lu.assertIs(plain[1], first)
    plain[1] = second
    lu.assertIs(filtered[1], first)
    local a, b = filtered:iter(), filtered:iter()
    lu.assertIs(a(), first)
    lu.assertIs(a(), first)
    lu.assertNil(a())
    lu.assertIs(b(), first)
end

function tests.test_cardinality_does_not_deduplicate_records()
    local row = { name = "one" }
    local empty = query.select({}, schema)
    lu.assertNil(empty:first())
    lu.assertFalse(empty:exists())
    lu.assertEquals(empty:count(), 0)
    local value, err = empty:one()
    lu.assertNil(value)
    assert_error(err, "no_match")
    value, err = empty:one_or_nil()
    lu.assertNil(value)
    lu.assertNil(err)
    local one = query.select({ row }, schema)
    lu.assertIs(one:one(), row)
    lu.assertIs(one:one_or_nil(), row)
    lu.assertTrue(one:exists())
    local duplicate = query.select({ row, row }, schema)
    value, err = duplicate:one()
    lu.assertNil(value)
    assert_error(err, "multiple_matches")
    value, err = duplicate:one_or_nil()
    lu.assertNil(value)
    assert_error(err, "multiple_matches")
end

function tests.test_ordinary_sequences_require_schema_even_when_empty()
    for _, call in ipairs({
        function()
            query.select({})
        end,
        function()
            query.filter({}, function()
                return true
            end)
        end,
        function()
            query.first({})
        end,
        function()
            query.one({})
        end,
        function()
            query.one_or_nil({})
        end,
        function()
            query.exists({})
        end,
        function()
            query.count({})
        end,
        function()
            query.iter({})
        end,
        function()
            query.to_table({})
        end,
    }) do
        local ok, err = pcall(call)
        lu.assertFalse(ok)
        assert_error(err, "invalid_schema")
    end
    local row = { name = "one" }
    lu.assertIs(query.first({ row }, schema), row)
    lu.assertIs(query.one({ row }, schema), row)
    lu.assertIs(query.one_or_nil({ row }, schema), row)
    lu.assertTrue(query.exists({ row }, schema))
    lu.assertEquals(query.count({ row, row }, schema), 2)
    lu.assertIs(query.iter({ row }, schema)(), row)
    lu.assertIs(query.to_table({ row }, schema)[1], row)
    lu.assertEquals(#query.filter({ row }, function()
        return false
    end, schema), 0)
end

function tests.test_sparse_sequences_and_predicate_errors_are_not_hidden()
    local ok, err = pcall(query.select, { [1] = {}, [3] = {} }, schema)
    lu.assertFalse(ok)
    assert_error(err, "invalid_sequence")
    local marker = {}
    local predicate_ok, predicate_error = pcall(function()
        query.select({ {} }, schema):filter(function()
            error(marker)
        end)
    end)
    lu.assertFalse(predicate_ok)
    lu.assertIs(predicate_error, marker)
end

local function fixture()
    return query.select({
        {
            name = "a.b",
            active = false,
            size = 0,
            title = query.NULL,
            children = {},
            parent = query.NULL,
        },
        {
            name = "alpha",
            active = true,
            size = 10,
            title = "",
            children = { { name = "x" }, { name = "y" } },
            parent = { name = "x" },
        },
        {
            name = "beta",
            active = false,
            size = 20,
            title = "label",
            children = { { name = "x" } },
            parent = { name = "y" },
        },
    }, schema)
end

local function names(rows)
    local result = {}
    for _, row in ipairs(rows) do
        result[#result + 1] = row.name
    end
    return result
end

local function compile_error(criteria, code, selected_schema)
    local compiled, err = query.compile(selected_schema or schema, criteria)
    lu.assertNil(compiled)
    assert_error(err, code)
end

function tests.test_scalar_operators_have_literal_typed_semantics()
    local rows = fixture()
    local cases = {
        { { active = false }, { "a.b", "beta" } },
        { { name = { eq = "alpha" } }, { "alpha" } },
        { { name = { ne = "alpha" } }, { "a.b", "beta" } },
        { { size = { gt = 0, lte = 10 } }, { "alpha" } },
        { { size = { gte = 10, lt = 20 } }, { "alpha" } },
        { { size = { one_of = { 0, 20 } } }, { "a.b", "beta" } },
        { { active = { none_of = { true } } }, { "a.b", "beta" } },
        { { name = { contains = "." } }, { "a.b" } },
        { { name = { starts_with = "a" } }, { "a.b", "alpha" } },
        { { name = { ends_with = "a" } }, { "alpha", "beta" } },
        { { name = { starts_with = "A" } }, {} },
        { { name = { contains = "" } }, { "a.b", "alpha", "beta" } },
        { { name = { ends_with = "" } }, { "a.b", "alpha", "beta" } },
        { { title = query.NULL }, { "a.b" } },
        { { title = { is_null = true } }, { "a.b" } },
        { { title = { is_null = false } }, { "alpha", "beta" } },
        { { title = { ne = query.NULL } }, { "alpha", "beta" } },
        { { title = { one_of = { query.NULL, "" } } }, { "a.b", "alpha" } },
        { { title = { contains = "" } }, { "alpha", "beta" } },
    }
    for _, case in ipairs(cases) do
        lu.assertEquals(names(rows:where(case[1])), case[2])
    end
end

function tests.test_boolean_and_membership_empty_identities()
    local rows = fixture()
    for _, case in ipairs({
        { {}, 3 },
        { { AND = {} }, 3 },
        { { OR = {} }, 0 },
        { { NOT = {} }, 0 },
        { { name = { one_of = {} } }, 0 },
        { { name = { none_of = {} } }, 3 },
        { { OR = { { active = true }, { size = { eq = 0 } } } }, 2 },
        { { NOT = { OR = { { active = true }, { size = 0 } } } }, 1 },
        { { AND = { { active = false }, { size = { gt = 0 } } } }, 1 },
    }) do
        lu.assertEquals(rows:where(case[1]):count(), case[2])
    end
end

function tests.test_relation_quantifiers_and_loaded_absence_truth_tables()
    local rows = fixture()
    for _, case in ipairs({
        { { children = { some = { name = "x" } } }, { "alpha", "beta" } },
        { { children = { every = { name = "x" } } }, { "a.b", "beta" } },
        { { children = { none = { name = "x" } } }, { "a.b" } },
        { { parent = { is = { name = "x" } } }, { "alpha" } },
        { { parent = { is_not = { name = "x" } } }, { "a.b", "beta" } },
        { { parent = { is = query.NULL } }, { "a.b" } },
        { { parent = { is_not = query.NULL } }, { "alpha", "beta" } },
    }) do
        lu.assertEquals(names(rows:where(case[1])), case[2])
    end
end

function tests.test_compile_copies_criteria_and_schema()
    local criteria = { name = { one_of = { "alpha" } } }
    local compiled, err = query.compile(schema, criteria)
    lu.assertNil(err)
    assert(compiled ~= nil)
    criteria.name.one_of[1] = "beta"
    criteria.size = 0
    lu.assertEquals(names(query.where(fixture(), compiled)), { "alpha" })
    lu.assertEquals(names(query.where(fixture():to_table(), compiled)), { "alpha" })
    lu.assertEquals(
        names(query.where(fixture():to_table(), { active = true }, schema)),
        { "alpha" }
    )
    local own_schema = { fields = { name = { type = "string" } } }
    local selected = query.select({ { name = "alpha" } }, own_schema)
    compiled = assert(query.compile(own_schema, { name = "alpha" }))
    own_schema.fields.name.type = "boolean"
    lu.assertEquals(#selected:where(compiled), 1)
end

function tests.test_invalid_grammar_is_rejected_before_empty_or_short_circuit()
    for _, criteria in ipairs({
        { absent_field = true },
        { OR = { {}, { absent_field = true } } },
        { NOT = { { active = true } } },
        { AND = { [2] = {} } },
        { name = { startsWith = "a" } },
        { name = { regex = ".*" } },
        { name = { lt = "a" } },
        { size = { contains = "1" } },
        { active = 0 },
        { active = query.NULL },
        { name = { is_null = false } },
        { title = { is_null = "yes" } },
        { size = { one_of = { "1" } } },
        { children = { is = {} } },
        { parent = { every = {} } },
        { children = {} },
        { name = {} },
    }) do
        compile_error(criteria, "invalid_criteria")
        local ok, err = pcall(function()
            query.select({}, schema):where(criteria)
        end)
        lu.assertFalse(ok)
        assert_error(err, "invalid_criteria")
    end
end

function tests.test_projection_validation_visits_all_rows_and_boolean_branches()
    local cases = {
        { { { active = true }, {} }, { active = true } },
        { { { active = true } }, { OR = { {}, { name = "x" } } } },
        { { { children = { { name = "x" }, {} } } }, { children = { some = { name = "x" } } } },
        { { { children = { { name = "no" }, {} } } }, { children = { every = { name = "x" } } } },
        { { {} }, { parent = { is = query.NULL } } },
        { { {} }, { parent = { is_not = query.NULL } } },
        { { {} }, { title = { is_null = true } } },
    }
    for _, case in ipairs(cases) do
        local ok, err = pcall(query.where, case[1], case[2], schema)
        lu.assertFalse(ok)
        assert_error(err, "unloaded_field")
    end
    compile_error({ future = true }, "unsupported_field", {
        fields = { future = { type = "boolean", supported = false } },
    })
    local ok, err = pcall(query.where, { { active = "0" } }, { active = false }, schema)
    lu.assertFalse(ok)
    assert_error(err, "invalid_data")
end

function tests.test_untrusted_criteria_reject_code_metatables_cycles_and_nonfinite_numbers()
    local cycle = {}
    cycle.NOT = cycle
    for _, criteria in ipairs({
        {
            active = function()
                return true
            end,
        },
        setmetatable({}, {
            __pairs = function()
                error("must not execute")
            end,
        }),
        { name = setmetatable({}, {}) },
        cycle,
        { size = 0 / 0 },
        { size = math.huge },
        { size = -math.huge },
        { name = { one_of = { "x", function() end } } },
    }) do
        compile_error(criteria, "invalid_criteria")
    end
    local shared = { active = false }
    local compiled, err = query.compile(schema, { AND = { shared, shared } })
    lu.assertNil(err)
    assert(compiled ~= nil)
    lu.assertEquals(#query.where(fixture(), compiled), 2)
end

function tests.test_untrusted_criteria_resource_limits_are_bounded()
    local depth = {}
    for _ = 1, 40 do
        depth = { NOT = depth }
    end
    compile_error(depth, "query_limit")
    local members = {}
    for i = 1, 1025 do
        members[i] = "x"
    end
    compile_error({ name = { one_of = members } }, "query_limit")
    compile_error({ name = string.rep("x", 65537) }, "query_limit")
    local clauses = {}
    for i = 1, 4097 do
        clauses[i] = {}
    end
    compile_error({ OR = clauses }, "query_limit")
end

function tests.test_schema_rejects_ambiguous_invalid_and_unsupported_positions()
    for _, invalid in ipairs({
        {},
        { fields = false },
        { relations = false },
        { fields = {}, relations = false },
        { fields = { x = { type = "function" } } },
        { fields = { OR = { type = "string" } } },
        { fields = { x = { type = "string", typo = true } } },
        {
            fields = { x = { type = "string" } },
            relations = { x = { cardinality = "one", schema = child } },
        },
        { relations = { x = { cardinality = "several", schema = child } } },
        setmetatable({ fields = {} }, {}),
    }) do
        local compiled, err = query.compile(invalid, {})
        lu.assertNil(compiled)
        assert_error(err, "invalid_schema")
    end
    local recursive = { fields = { name = { type = "string" } }, relations = {} }
    recursive.relations.parent = { cardinality = "one", nullable = true, schema = recursive }
    local rows = { { name = "child", parent = { name = "root", parent = query.NULL } } }
    lu.assertEquals(#query.where(rows, { parent = { is = { name = "root" } } }, recursive), 1)
end

function tests.test_compiled_queries_cannot_bypass_the_selection_schema()
    local compiled =
        assert(query.compile({ fields = { name = { type = "string" } } }, { name = "x" }))
    local incompatible = query.select({}, { fields = { name = { type = "number" } } })
    local ok, err = pcall(function()
        incompatible:where(compiled)
    end)
    lu.assertFalse(ok)
    assert_error(err, "invalid_schema")
    local unavailable = query.select(
        {},
        { fields = { name = { type = "string", supported = false } } }
    )
    ok, err = pcall(function()
        unavailable:where(compiled)
    end)
    lu.assertFalse(ok)
    assert_error(err, "unsupported_field")
end

function tests.test_record_and_sequence_metatables_cannot_execute_during_queries()
    local called = false
    local dangerous = setmetatable({}, {
        __index = function()
            called = true
            return "x"
        end,
        __pairs = function()
            called = true
            return next, {}, nil
        end,
    })
    local ok, err = pcall(query.where, { dangerous }, { name = "x" }, schema)
    lu.assertFalse(ok)
    assert_error(err, "invalid_data")
    ok, err = pcall(query.where, dangerous, {}, schema)
    lu.assertFalse(ok)
    assert_error(err, "invalid_sequence")
    lu.assertFalse(called)
end

return tests
