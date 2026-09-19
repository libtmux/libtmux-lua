local test = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local process = require("libtmux._internal.process")
local available, execution = pcall(require, "libtmux._internal.execution")
local M = {}

local function fixture(options)
    test.assertTrue(available, "public command execution is missing")
    local driver = drivers.new()
    local runtime = runtimes.new(driver, options)
    local calls, pending = {}, {}
    local bound = {}
    local function submit(commands, opts, raw)
        local call = { commands = commands, options = opts, raw = raw }
        calls[#calls + 1] = call
        call.request = runtime:_request({
            effect = "unknown",
            start = function(settle, retire)
                local name = commands[1][1]
                if name == "h" then
                    pending.settle, pending.retire = settle, retire
                    return function()
                        pending.cancelled = true
                    end
                end
                local result = {
                    stdout = name == "f" and "bad" or name == "large" and "12345678" or "ok",
                    stderr = name == "f" and "err" or "",
                    exit_code = name == "f" and 1 or 0,
                    signal = 0,
                }
                if name == "p" then
                    settle(nil, {
                        code = "stale_generation",
                        effect = "not_sent",
                        cause = {
                            code = "uncertain_generation",
                            cause = {
                                code = "exit_failed",
                                partial = result,
                            },
                        },
                    })
                elseif name == "incomplete" then
                    settle(nil, { code = "drain_timeout", effect = "completed", partial = result })
                elseif result.exit_code ~= 0 and not raw then
                    settle(nil, { code = "exit_failed", effect = "completed", partial = result })
                else
                    settle(result)
                end
                retire()
            end,
        })
        return call.request
    end
    function bound.group(_, commands, opts)
        return submit(commands, opts, true)
    end
    function bound.execute(_, argv, opts)
        return submit({ argv }, opts, false)
    end
    return runtime, driver, bound, calls, pending
end

function M.test_process_preparation_is_pure_and_copies_inputs()
    test.assertEquals(type(process.prepare), "function", "pure process preparation is missing")
    local argv, options = { "program", "literal;" }, { env = { "K=original" }, stdin = "x\000y" }
    local prepared, err = process.prepare(argv, options)
    test.assertNil(err)
    prepared = assert(prepared)
    test.assertEquals(prepared.argv, argv)
    test.assertEquals(prepared.options.max_output_bytes, 1048576)
    argv[2], options.env[1] = "changed", "K=changed"
    test.assertEquals(prepared.argv[2], "literal;")
    test.assertEquals(prepared.options.env[1], "K=original")
    test.assertEquals(prepared.bytes, #"programliteral;K=originalx\000y")
    prepared, err = process.prepare({ "program" }, { max_output_bytes = false })
    test.assertNil(prepared)
    test.assertEquals(assert(err).code, "invalid_options")
    test.assertEquals(assert(err).effect, "not_sent")
end

function M.test_raw_command_and_group_keep_actual_exit_data_and_direct_requests()
    local rt, driver, bound, calls = fixture()
    local root = rt:start(function()
        local argv, options = { "f", "literal;" }, { env = { "K=before" } }
        local request = execution.command(rt, bound, argv, options)
        test.assertIs(request, calls[1].request)
        argv[2], options.env[1] = "changed", "K=after"
        local result, err = request:await()
        test.assertNil(err)
        test.assertEquals(result, { stdout = "bad", stderr = "err", exit_code = 1, signal = 0 })
        test.assertEquals(calls[1].commands, { { "f", "literal;" } })
        test.assertEquals(calls[1].options.env, { "K=before" })
        result, err = execution.group(rt, bound, { { "f" }, { "not-attributed" } }):await()
        test.assertNil(err)
        test.assertEquals(result.exit_code, 1)
        test.assertNil(result.members)
        result, err = execution.command(rt, bound, { "incomplete" }):await()
        test.assertNil(result)
        test.assertEquals(err.code, "drain_timeout")
    end)
    driver:drain()
    test.assertTrue(root:is_retired())
    test.assertNil(select(2, root:result()))
end

function M.test_whole_group_and_batch_validation_precedes_bound_side_effects()
    local rt, driver, bound, calls = fixture()
    local touched = false
    local bad = setmetatable({}, {
        __index = function()
            touched = true
        end,
    })
    local root = rt:start(function()
        local cases = {
            function()
                return execution.group(rt, bound, { { "mutate" }, { "bad\000" } })
            end,
            function()
                return execution.batch(rt, bound, { { "mutate" }, {} })
            end,
            function()
                return execution.batch(
                    rt,
                    bound,
                    { { "mutate" } },
                    { process = { env = { false } } }
                )
            end,
            function()
                return execution.command(rt, bound, { "mutate" }, { timeout = false })
            end,
            function()
                return execution.command(rt, bound, { "mutate" }, { deadline = math.huge })
            end,
            function()
                return execution.command(rt, bound, { "mutate" }, { deadline = 1e20 })
            end,
            function()
                return execution.command(rt, bound, bad)
            end,
            function()
                return execution.batch(rt, bound, { { "mutate" } }, { concurrency = 129 })
            end,
        }
        for _, submit in ipairs(cases) do
            local result, err = submit():await()
            test.assertNil(result)
            test.assertEquals(err.effect, "not_sent")
        end
    end)
    driver:drain()
    test.assertTrue(root:is_retired())
    test.assertNil(select(2, root:result()))
    test.assertEquals(calls, {})
    test.assertFalse(touched)
end

function M.test_batch_indexed_failures_keep_actual_result_and_account_output()
    local rt, driver, bound = fixture({ max_bytes = 10, max_active = 1 })
    local root = rt:start(function()
        local outcomes = assert(execution.batch(rt, bound, { { "s" }, { "f" } }):await())
        test.assertEquals(outcomes[1].status, "completed")
        test.assertEquals(outcomes[2].status, "failed")
        test.assertEquals(outcomes[2].error.code, "exit_failed")
        test.assertEquals(outcomes[2].error.partial.stdout, "bad")
        test.assertEquals(outcomes[2].error.partial.stderr, "err")
        test.assertEquals(outcomes[2].effect, "completed")
        return outcomes
    end)
    driver:drain()
    test.assertNil(select(2, root:result()))
    test.assertTrue(root:is_retired())
    test.assertEquals(rt:stats().bytes, 0)
end

function M.test_batch_byte_overflow_omits_excess_strings_and_continues()
    local rt, driver, bound = fixture({ max_bytes = 9 })
    local root = rt:start(function()
        return execution.batch(rt, bound, { { "s" }, { "f" }, { "s" }, { "p" } }):await()
    end)
    driver:drain()
    local outcomes = assert(root:result())
    local err = outcomes[2].error
    test.assertEquals(err.code, "queue_full")
    test.assertEquals(err.effect, "completed")
    test.assertEquals(err.partial, {
        output_truncated = true,
        stdout_bytes = 3,
        stderr_bytes = 3,
        exit_code = 1,
        signal = 0,
    })
    test.assertNil(err.cause and err.cause.partial)
    test.assertEquals(outcomes[3].value.stdout, "ok")
    test.assertEquals(outcomes[4].error.code, "queue_full")
    test.assertEquals(outcomes[4].error.effect, "not_sent")
    test.assertEquals(outcomes[4].error.partial.stdout_bytes, 2)
    test.assertNil(outcomes[4].error.cause.cause)
    test.assertEquals(rt:stats().bytes, 0)
end

function M.test_batch_cancellation_preserves_retained_completed_output_until_retirement()
    local rt, driver, bound, calls, pending = fixture({ max_bytes = 8 })
    local request
    local root = rt:start(function()
        request = execution.batch(rt, bound, { { "s" }, { "h" }, { "n" } })
        request:await()
    end)
    driver:drain()
    test.assertEquals(rt:stats().bytes, 5)
    request:cancel()
    driver:drain()
    local _, err = request:result()
    test.assertEquals(err.partial.outcomes[1].value.stdout, "ok")
    test.assertEquals(err.partial.outcomes[2].status, "unknown")
    test.assertEquals(err.partial.outcomes[3].status, "skipped")
    test.assertEquals(#calls, 2)
    test.assertTrue(pending.cancelled)
    test.assertFalse(request:is_retired())
    test.assertEquals(rt:stats().bytes, 5)
    pending.retire()
    driver:drain()
    test.assertTrue(root:is_retired())
    test.assertEquals(rt:stats().bytes, 0)
    test.assertEquals(err.partial.outcomes[1].value.stdout, "ok")
end

function M.test_copied_batch_input_is_bounded_before_deferred_dispatch()
    local rt, driver, bound, calls = fixture({ max_bytes = 8 })
    local root = rt:start(function()
        local request = execution.batch(rt, bound, { { "large", string.rep("x", 1024) } })
        local value, err = request:result()
        test.assertNil(value)
        test.assertEquals(err.code, "queue_full")
        test.assertEquals(err.effect, "not_sent")
        test.assertEquals(err.partial.outcomes[1].status, "skipped")
        test.assertTrue(request:is_retired())
        test.assertEquals(rt:stats().bytes, 0)
        test.assertEquals(calls, {})
    end)
    driver:drain()
    test.assertNil(select(2, root:result()))
    test.assertTrue(root:is_retired())
end

return M
