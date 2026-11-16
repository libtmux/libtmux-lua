-- Proves the CI plan picks what each event should run, and that it can fail.
--
-- Every rule has a check, and every check has a deliberate break: the rule is replaced with its
-- absence and the check has to notice. A check that passes with its rule removed would prove
-- nothing about the rule.
local test = require("luaunit")
local planner = require("ci_plan.planner")
local C = require("ci_plan.tests.plan_checks")
local DELIBERATE_BREAKS = require("ci_plan.tests.plan_breaks")
local NAMES = C.names

local M = {}

local function sorted_names(allowed)
    local names = {}
    for check, name in pairs(NAMES) do
        if allowed(check) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- Reports whether `check` fails, as opposed to passing or breaking for another reason.
local function fails(check)
    local ok, failure = pcall(check)
    if ok then
        return false
    end
    if type(failure) == "string" and failure:find(test.FAILURE_PREFIX, 1, true) then
        return true
    end
    error(failure, 0)
end

local function fails_with_rule_replaced(rule, replacement, check)
    local original = planner[rule]
    planner[rule] = replacement
    local ok, result = pcall(fails, check)
    planner[rule] = original
    if not ok then
        error(result, 0)
    end
    return result
end

for index, each in ipairs(DELIBERATE_BREAKS) do
    local description, rule, replacement, check = unpack(each)
    local slug = description:lower():gsub("[^%w]+", "_")
    M[("test_break_%02d_%s"):format(index, slug)] = function()
        test.assertNotNil(planner[rule], rule)
        check()
        test.assertTrue(fails_with_rule_replaced(rule, replacement, check), description)
    end
end

function M.test_every_check_has_a_deliberate_break()
    local broken = {}
    for _, each in ipairs(DELIBERATE_BREAKS) do
        broken[each[4]] = true
    end
    -- These state a default or a boundary that no single removal can reach.
    test.assertEquals(
        sorted_names(function(check)
            return not broken[check]
        end),
        { "a_single_release_is_one_edge", "no_debug_session_by_default" }
    )
end

return M
