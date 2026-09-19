local test = require("luaunit")
local runtime = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local available, composition = pcall(require, "libtmux._internal.batch")
local M = {}

local function fixture(options)
    test.assertTrue(available, "batch and sequence implementation is missing")
    local driver = drivers.new()
    return runtime.new(driver, options), driver
end

local function pending(rt, operations, index)
    local state = { stopped = 0 }
    operations[index] = state
    return rt:_request({
        effect = "unknown",
        start = function(settle, retire)
            state.started, state.settle, state.retire = true, settle, retire
            return function()
                state.stopped = state.stopped + 1
            end
        end,
    })
end

function M.test_batch_concurrency_preserves_indices_and_copied_tasks()
    local rt, driver = fixture({ max_active = 2 })
    local operations, tasks = {}, {}
    local results
    for index = 1, 3 do
        tasks[index] = {
            run = function(inner)
                return pending(inner, operations, index):await()
            end,
        }
    end
    local root = rt:start(function()
        local request = composition.batch(rt, tasks, { concurrency = 2 })
        tasks[1].run = function()
            error("task was not copied")
        end
        tasks[3] = nil
        results = assert(request:await())
    end)
    driver:drain()
    test.assertTrue(operations[1].started and operations[2].started)
    test.assertNil(operations[3])
    operations[2].settle("second")
    operations[2].retire()
    driver:drain()
    test.assertTrue(operations[3].started)
    operations[3].settle(false)
    operations[3].retire()
    operations[1].settle("first")
    operations[1].retire()
    driver:drain()
    test.assertTrue(root:is_retired())
    test.assertEquals(results, {
        { status = "completed", value = "first", effect = "completed" },
        { status = "completed", value = "second", effect = "completed" },
        { status = "completed", value = false, effect = "completed" },
    })
end

function M.test_batch_failures_are_indexed_and_do_not_cancel_siblings()
    local rt, driver = fixture()
    local expected = { code = "invalid_target", effect = "not_sent" }
    local uncertain = { code = "unknown_outcome", effect = "unknown" }
    local order = {}
    local results
    local root = rt:start(function()
        results = assert(composition
            .batch(rt, {
                {
                    run = function()
                        order[#order + 1] = 1
                        return nil, expected
                    end,
                },
                {
                    run = function()
                        order[#order + 1] = 2
                        error(uncertain)
                    end,
                },
                {
                    run = function()
                        order[#order + 1] = 3
                        return "survived"
                    end,
                },
            })
            :await())
        return "root survived"
    end)
    driver:drain()
    test.assertEquals(root:result(), "root survived")
    test.assertEquals(order, { 1, 2, 3 })
    test.assertEquals(results[1], { status = "failed", error = expected, effect = "not_sent" })
    test.assertEquals(results[2], { status = "unknown", error = uncertain, effect = "unknown" })
    test.assertEquals(results[3].value, "survived")
end

function M.test_sequence_passes_copied_receipts_and_skips_after_uncertainty()
    local rt, driver = fixture({ max_active = 1 })
    local skipped = false
    local results
    local uncertain = { code = "lost_reply", effect = "unknown" }
    local root = rt:start(function()
        results = assert(composition
            .sequence(rt, {
                {
                    run = function(inner, previous)
                        test.assertEquals(previous, {})
                        return inner
                            :_request({
                                start = function(settle, retire)
                                    driver.defer(function()
                                        settle("@12")
                                        retire()
                                    end)
                                end,
                            })
                            :await()
                    end,
                },
                {
                    run = function(_, previous)
                        test.assertEquals(previous[1].value, "@12")
                        previous[1].status = "changed"
                        previous[2] = {}
                        return nil, uncertain
                    end,
                },
                {
                    run = function()
                        skipped = true
                    end,
                },
            })
            :await())
    end)
    driver:drain()
    test.assertTrue(root:is_retired())
    test.assertFalse(skipped)
    test.assertEquals(results, {
        { status = "completed", value = "@12", effect = "completed" },
        { status = "unknown", error = uncertain, effect = "unknown" },
        { status = "skipped", effect = "not_sent" },
    })
end

function M.test_entire_input_is_validated_before_any_task_effect()
    local rt, driver = fixture()
    local called = false
    local task = {
        run = function()
            called = true
        end,
    }
    local too_many = {}
    for index = 1, 1025 do
        too_many[index] = task
    end
    local cases = {
        { { task, {} } },
        { { [1] = task, [3] = task } },
        { too_many },
        { { task }, { concurrency = 0 } },
        { { task }, { concurrency = 129 } },
        { { task }, { concurrency = math.huge } },
        { { task }, { unexpected = true } },
        {
            {
                setmetatable({}, {
                    __index = function()
                        called = true
                    end,
                }),
            },
        },
    }
    local root = rt:start(function()
        for _, case in ipairs(cases) do
            local value, err = composition.batch(rt, case[1], case[2]):await()
            test.assertNil(value)
            test.assertEquals(err.code, "invalid_batch")
            test.assertEquals(err.effect, "not_sent")
        end
        local value, err = composition.sequence(rt, { task }, { concurrency = 2 }):await()
        test.assertNil(value)
        test.assertEquals(err.code, "invalid_batch")
        test.assertEquals(composition.batch(rt, {}):await(), {})
    end)
    driver:drain()
    test.assertFalse(called)
    test.assertTrue(root:is_retired())
end

function M.test_cancel_receipts_preserve_completed_and_never_started_outcomes()
    for _, mode in ipairs({ "explicit", "root", "before_callback" }) do
        local rt, driver = fixture({ max_active = 2 })
        local operations, tasks = {}, {}
        local request
        for index = 1, 4 do
            tasks[index] = {
                run = function(inner)
                    return pending(inner, operations, index):await()
                end,
            }
        end
        local root = rt:start(function()
            request = composition.batch(rt, tasks, { concurrency = 2 })
            request:await()
            return "caught cancellation"
        end)
        driver:drain()
        operations[1].settle("completed")
        operations[1].retire()
        if mode ~= "before_callback" then
            driver:drain()
            test.assertTrue(operations[3].started)
        else
            driver:step()
        end
        if mode == "root" then
            rt:close("cancel composition through root")
        else
            request:cancel("cancel composition explicitly")
        end
        driver:drain()
        local value, err = request:result()
        test.assertNil(value)
        test.assertEquals(err.code, "cancelled")
        local outcomes = err.partial.outcomes
        test.assertEquals(outcomes, {
            { status = "completed", value = "completed", effect = "completed" },
            { status = "unknown", effect = "unknown" },
            mode == "before_callback" and { status = "skipped", effect = "not_sent" }
                or { status = "unknown", effect = "unknown" },
            { status = "skipped", effect = "not_sent" },
        })
        test.assertNil(operations[4])
        test.assertEquals(operations[2].stopped, 1)
        if operations[3] then
            test.assertEquals(operations[3].stopped, 1)
        end
        test.assertFalse(request:is_retired())
        for index = 2, operations[3] and 3 or 2 do
            operations[index].settle("late success")
            operations[index].retire()
        end
        driver:drain()
        test.assertTrue(request:is_retired())
        test.assertTrue(root:is_retired())
        test.assertEquals(outcomes[2], { status = "unknown", effect = "unknown" })
        test.assertEquals(rt:stats().active, 0)
    end
end

function M.test_task_and_callback_admission_never_silently_skips_required_work()
    for _, task_limit in ipairs({ 2, 3 }) do
        local rt, driver = fixture({ max_tasks = task_limit })
        local calls = 0
        local request
        local tasks = {}
        for index = 1, 3 do
            tasks[index] = {
                run = function()
                    calls = calls + 1
                    test.assertTrue(rt:stats().tasks <= task_limit)
                    return index
                end,
            }
        end
        local root = rt:start(function()
            request = composition.batch(rt, tasks, { concurrency = 128 })
            request:await()
        end)
        driver:drain()
        local results, err = request:result()
        if task_limit == 2 then
            test.assertNil(results)
            test.assertEquals(err.code, "queue_full")
            test.assertEquals(err.effect, "not_sent")
            test.assertEquals(calls, 0)
        else
            test.assertNil(err)
            test.assertEquals(calls, 3)
            test.assertEquals(results[3].value, 3)
        end
        test.assertTrue(root:is_retired())
    end
    local rt, driver = fixture({ max_callbacks = 1 })
    local request
    local task = {
        run = function()
            return "done"
        end,
    }
    local root = rt:start(function()
        request = composition.batch(rt, { task, task, task, task }, { concurrency = 2 })
        request:await()
    end)
    driver:drain()
    local results, err = request:result()
    test.assertNil(results)
    test.assertEquals(err.code, "queue_full")
    test.assertEquals(err.partial.outcomes[1].status, "completed")
    test.assertEquals(err.partial.outcomes[2].status, "completed")
    test.assertEquals(err.partial.outcomes[3].status, "skipped")
    test.assertTrue(root:is_retired())
end

function M.test_finished_items_do_not_consume_unneeded_completion_slots()
    for _, count in ipairs({ 1, 3 }) do
        local rt, driver = fixture({ max_callbacks = 1 })
        local tasks, called = {}, 0
        for index = 1, count do
            tasks[index] = {
                run = function()
                    called = called + 1
                    return index
                end,
            }
        end
        local root = rt:start(function()
            return composition.batch(rt, tasks, { concurrency = 2 }):await()
        end)
        if count == 1 then
            root:on_complete(function() end)
        end
        driver:drain()
        local outcomes, err = root:result()
        test.assertNil(err)
        test.assertEquals(called, count)
        test.assertEquals(assert(outcomes)[count].value, count)
        test.assertTrue(root:is_retired())
    end
end

function M.test_cancel_before_execution_reports_only_skipped_steps()
    local rt, driver = fixture()
    local called = false
    local request
    local root = rt:start(function()
        request = composition.batch(rt, {
            {
                run = function()
                    called = true
                end,
            },
        })
        request:await()
    end)
    driver:step()
    request:cancel()
    driver:drain()
    local _, err = request:result()
    test.assertEquals(err.effect, "not_sent")
    test.assertEquals(err.partial.outcomes, { { status = "skipped", effect = "not_sent" } })
    test.assertFalse(called)
    test.assertTrue(root:is_retired())
end

function M.test_concurrency_slot_waits_for_failed_child_native_retirement()
    local rt, driver = fixture({ max_active = 1 })
    local operations, later = {}, false
    local request
    local root = rt:start(function()
        request = composition.batch(rt, {
            {
                run = function(inner)
                    return pending(inner, operations, 1):await()
                end,
            },
            {
                run = function()
                    later = true
                    return "next"
                end,
            },
        })
        return request:await()
    end)
    driver:drain()
    operations[1].settle(nil, { code = "failed", effect = "unknown" })
    driver:drain()
    test.assertFalse(later)
    test.assertFalse(request:is_settled())
    operations[1].retire()
    driver:drain()
    test.assertTrue(later)
    test.assertTrue(root:is_retired())
    local results = assert(root:result())
    test.assertEquals(results[1].status, "unknown")
    test.assertEquals(results[2].value, "next")
end

return M
