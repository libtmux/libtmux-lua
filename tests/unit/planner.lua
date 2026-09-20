local test = require("luaunit")
local query = require("libtmux.query")
local graph = require("libtmux._internal.graph")
local available, planner = pcall(require, "libtmux._internal.planner")
local M = {}

local function plan(options, version)
    test.assertTrue(available, "live query planner is not implemented")
    local value, err = planner.new(version or "3.7c", options)
    test.assertNotNil(value, tostring(err))
    return value
end

function M.test_every_entity_kind_supports_validated_local_evaluation()
    local cases = {
        { "session", "name", "keep", "list-sessions" },
        { "window", "name", "keep", "list-windows" },
        { "pane", "active", false, "list-panes" },
        { "window_link", "index", 7, "list-windows" },
        { "client", "name", "keep", "list-clients" },
        { "buffer", "name", "keep", "list-buffers" },
    }
    for _, case in ipairs(cases) do
        local row = { [case[2]] = case[3] }
        for _, mode in ipairs({ "never", "auto" }) do
            local compiled = plan({ kind = case[1], where = row, pushdown = mode })
            local selected = assert(planner.apply(compiled, { row, row }))
            test.assertEquals(#selected, 2)
            test.assertIs(selected[1], row)
            test.assertEquals(planner.explain(compiled).source.argv[1], case[4])
        end
        if case[1] ~= "pane" then
            local value, err = planner.new("3.7c", { kind = case[1], pushdown = "require" })
            test.assertNil(value)
            test.assertEquals(assert(err).code, "unsupported_pushdown")
        end
    end
    local first, second = graph.schemas("3.7c"), graph.schemas("3.7c")
    first.pane.fields.id.type = "number"
    test.assertEquals(second.pane.fields.id.type, "string")
    test.assertIs(second.pane.relations.window.schema, second.window)
end

function M.test_whole_criteria_validate_before_empty_input_or_translation()
    plan({})
    for _, mode in ipairs({ "never", "auto", "require" }) do
        local value, err = planner.new("3.7c", {
            pushdown = mode,
            where = { OR = { {}, { no_such_field = 1 } } },
        })
        test.assertNil(value)
        test.assertEquals(assert(err).code, "invalid_criteria")
    end
    local value, err = planner.new("3.2a", { where = { dead_signal = "TERM" } })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "unsupported_field")
    local invalid = { { kind = "server" }, { pushdown = "sometimes" }, { extra = true } }
    for _, options in ipairs(invalid) do
        value, err = planner.new("3.7c", options)
        test.assertNil(value)
        test.assertIsTable(err)
    end
    local criteria = {}
    criteria.NOT = criteria
    value, err = planner.new("3.7c", { where = criteria })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "invalid_criteria")
end

function M.test_exact_pane_equality_uses_catalog_aliases_and_canonical_numbers()
    for _, case in ipairs({
        { "id", "%9", "pane_id", "%9" },
        { "window_id", "@7", "window_id", "@7" },
        { "active", false, "pane_active", "0" },
        { "dead", true, "pane_dead", "1" },
        { "synchronized", false, "pane_synchronized", "0" },
        { "index", 0, "pane_index", "0" },
        { "width", 39.0, "pane_width", "39" },
        { "height", 10, "pane_height", "10" },
        { "left", -1 / math.huge, "pane_left", "0" },
        { "top", 3, "pane_top", "3" },
        { "pid", 123, "pane_pid", "123" },
        { "mode_count", 1, "pane_in_mode", "1" },
    }) do
        local compiled = plan({ pushdown = "require", where = { [case[1]] = case[2] } })
        local explained = assert(planner.explain(compiled))
        test.assertTrue(explained.exact)
        test.assertEquals(explained.filter, "#{==:#{" .. case[3] .. "}," .. case[4] .. "}")
        test.assertEquals(explained.source.argv, { "list-panes", "-a", "-f", explained.filter })
        test.assertEquals(explained.fields.panes, { case[1] })
        test.assertEquals(#assert(planner.apply(compiled, { { [case[1]] = case[2] } })), 1)
    end
    local empty = assert(planner.explain(plan({ where = {}, pushdown = "require" })))
    test.assertTrue(empty.exact)
    test.assertNil(empty.filter)
end

function M.test_auto_only_prunes_necessary_conjuncts_and_require_refuses_residuals()
    for _, where in ipairs({
        { OR = { { active = true }, { title = "needle" } } },
        { NOT = { active = true, title = "needle" } },
        { title = "#{pane_id},#(unsafe)" },
        { id = "%0},#{pane_id}" },
        { dead_status = query.NULL },
        { width = 1.5 },
        { width = 9007199254740992 },
        { width = { gt = 5 } },
    }) do
        local compiled = plan({ where = where })
        test.assertNil(planner.explain(compiled).filter)
        local value, err = planner.new("3.7c", { where = where, pushdown = "require" })
        test.assertNil(value)
        test.assertEquals(assert(err).code, "unsupported_pushdown")
    end
    local compiled = plan({
        where = {
            active = false,
            OR = { { title = "needle" }, { width = 20 } },
        },
    })
    local explained = assert(planner.explain(compiled))
    test.assertEquals(explained.filter, "#{==:#{pane_active},0}")
    test.assertEquals(explained.fields.panes, { "active", "title", "width" })
    test.assertFalse(explained.exact)
    local rows = { { active = false, title = "needle", width = 10 } }
    test.assertEquals(#assert(planner.apply(compiled, rows)), 1)
    rows[1].title = nil
    local selected, err = planner.apply(compiled, rows)
    test.assertNil(selected)
    test.assertEquals(assert(err).code, "unloaded_field")
end

function M.test_compilation_and_explain_do_not_expose_mutable_plan_state()
    local where = { AND = { { active = false }, { index = 2 } } }
    local compiled = plan({ where = where })
    local before = assert(planner.explain(compiled))
    where.AND[1].active = true
    where.AND[2].index = 3
    compiled.where = { active = true }
    local changed = assert(planner.explain(compiled))
    changed.source.argv[1] = "kill-server"
    changed.fields.panes[1] = "injected"
    changed.pushed[1].value = "injected"
    test.assertEquals(planner.explain(compiled), before)
    local row = { active = false, index = 2 }
    test.assertIs(assert(planner.apply(compiled, { row }))[1], row)
    local value, err = planner.apply({}, {})
    test.assertNil(value)
    test.assertEquals(assert(err).code, "invalid_plan")
end

function M.test_retained_cost_covers_copied_values_and_stays_private()
    local criteria = { title = "short" }
    local small = plan({ where = criteria })
    test.assertIsFunction(planner.cost)
    local before = assert(planner.cost(small))
    test.assertTrue(before > #criteria.title)
    local large = plan({ where = { title = string.rep("x", 2005) } })
    test.assertTrue(assert(planner.cost(large)) >= before + 2000)
    criteria.title = string.rep("y", 60000)
    small.cycle = small
    local explained = assert(planner.explain(small))
    explained.extra = criteria.title
    test.assertEquals(planner.cost(small), before)
    local bytes, err = planner.cost({})
    test.assertNil(bytes)
    test.assertEquals(assert(err).code, "invalid_plan")
end

function M.test_candidate_filter_keeps_complete_relationship_universe()
    local active, inactive = { active = true }, { active = false }
    local window = { panes = { active, inactive } }
    active.window, inactive.window = window, window
    local compiled = plan({
        where = {
            active = true,
            window = { is = { panes = { every = { active = true } } } },
        },
    })
    local explained = assert(planner.explain(compiled))
    test.assertEquals(explained.filter, "#{==:#{pane_active},1}")
    test.assertEquals(explained.hydration, { "window", "window.panes" })
    test.assertEquals(#assert(planner.apply(compiled, { active })), 0)
    test.assertIs(active.window.panes[2], inactive)
    local missing = { active = false }
    local selected, err = planner.apply(compiled, { missing })
    test.assertNil(selected)
    test.assertEquals(assert(err).code, "unloaded_field")
end

function M.test_native_expression_bounds_preserve_local_semantics()
    local terms = {}
    for index = 1, 256 do
        terms[index] = { active = true }
    end
    local explained =
        assert(planner.explain(plan({ where = { AND = terms }, pushdown = "require" })))
    test.assertTrue(explained.exact)
    test.assertTrue(#explained.filter <= 16384)
    local level, deepest = 0, 0
    for char in explained.filter:gmatch(".") do
        if char == "{" then
            level = level + 1
            deepest = math.max(deepest, level)
        elseif char == "}" then
            level = level - 1
        end
    end
    test.assertTrue(deepest <= 10)
    terms[257] = { active = true }
    local value, err = planner.new("3.7c", { where = { AND = terms }, pushdown = "require" })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "unsupported_pushdown")
    local partial = plan({ where = { AND = terms } })
    test.assertEquals(#planner.explain(partial).pushed, 256)
    test.assertEquals(#assert(planner.apply(partial, { { active = true } })), 1)
    local long_id = "%" .. string.rep("1", 20000)
    local bounded = plan({ where = { id = long_id } })
    test.assertNil(planner.explain(bounded).filter)
    test.assertEquals(#assert(planner.apply(bounded, { { id = long_id } })), 1)
end

return M
