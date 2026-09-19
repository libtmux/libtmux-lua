local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local errors = require("libtmux._internal.error")
local available, environment = pcall(require, "libtmux._internal.environment")
local M = {}

local function missing(name)
    return errors.new("exit_failed", "process exited unsuccessfully", {
        effect = "completed",
        partial = {
            stdout = "",
            stderr = "unknown variable: " .. name .. "\n",
            exit_code = 1,
            signal = 0,
        },
    })
end

local function fixture(body, limits, kind)
    t.assertTrue(available, "persistent environment operations are missing")
    local driver = drivers.new()
    local rt = runtimes.new(driver, limits)
    local generation =
        assert(identity.generation({ pid = "1", started = "2", socket = "s", version = "3.7c" }))
    local state = { runtime = rt, version = "3.7c", calls = {}, outputs = {} }
    local function dispatch(commands, options, grouped)
        state.calls[#state.calls + 1] =
            { commands = commands, options = options, grouped = grouped }
        return rt:_operation(function()
            if state.before then
                state.before()
            end
            local output = table.remove(state.outputs, 1) or ""
            if type(output) == "table" then
                if output.code then
                    return nil, output
                end
                return output
            end
            return { stdout = output, stderr = "", exit_code = 0, signal = 0 }
        end)
    end
    state.bound = {
        generation = function()
            local evidence, err = identity.evidence(generation)
            return evidence and generation, err
        end,
        execute = function(_, argv, options)
            return dispatch({ argv }, options, false)
        end,
        group = function(_, commands, options)
            return dispatch(commands, options, true)
        end,
    }
    local owned
    if kind ~= false then
        owned = assert(identity.bind(generation, {
            kind = kind or "session",
            id = kind == "pane" and "%2" or "$2",
            generation = generation,
        }))
    end
    local function run(action, name, value, options)
        return environment.run(state, owned, action, name, value, options)
    end
    local root = rt:start(function()
        return body(state, run, generation)
    end)
    driver:drain()
    local _, err = root:result()
    t.assertNil(err)
    t.assertTrue(root:is_retired())
    t.assertEquals(rt:stats().bytes, 0)
end

function M.test_named_empty_hidden_removed_absent_and_exact_unknown_error()
    fixture(function(state, run)
        state.outputs = {
            'A=""; export A;\n',
            "",
            'A="secret\\$x\n\255"; export A;\n',
            "unset A;\n",
            missing("A"),
        }
        local value = assert(run("get", "A"):await())
        t.assertEquals(value.value, "")
        t.assertEquals(value.state, "value")
        t.assertFalse(value.hidden)
        t.assertEquals(value.scope, "session")
        t.assertEquals(value.target.id, "$2")
        value = assert(run("get", "A"):await())
        t.assertEquals(value.value, "secret$x\n\255")
        t.assertTrue(value.hidden)
        value = assert(run("get", "A"):await())
        t.assertEquals(value.state, "removed")
        value = assert(run("get", "A"):await())
        t.assertEquals(value.state, "absent")
        t.assertNil(value.hidden)
        t.assertEquals(
            state.calls[3].commands[1],
            { "show-environment", "-t", "$2", "-s", "-h", "--", "A" }
        )
        state.outputs = { missing("OTHER") }
        local result, err = run("get", "A"):await()
        t.assertNil(result)
        err = assert(err)
        t.assertEquals(err.code, "exit_failed")
        t.assertEquals(err.partial.stderr, "unknown variable: OTHER\n")
        state.outputs = { "", "" }
        result, err = run("get", "A"):await()
        t.assertNil(result)
        t.assertEquals(assert(err).code, "inconsistent")
    end)
end

function M.test_inheritance_respects_local_hidden_and_removed_entries()
    fixture(function(state, run)
        state.outputs = { missing("A"), 'A="global"; export A;\n' }
        local value = assert(run("get", "A", nil, { inherit = true }):await())
        t.assertTrue(value.inherited)
        t.assertEquals(value.scope, "global")
        t.assertNil(value.target)
        state.outputs = { missing("A"), missing("A") }
        value = assert(run("get", "A", nil, { inherit = true }):await())
        t.assertFalse(value.inherited)
        t.assertEquals(value.scope, "session")
        state.outputs = {
            'LOCAL="x"; export LOCAL;\nunset MASK;\n',
            'SECRET="hidden"; export SECRET;\n',
            "unset MASK;\n",
            'MASK="global"; export MASK;\n'
                .. 'SECRET="global"; export SECRET;\nZ="fallback"; export Z;\n',
        }
        value = assert(run("list", nil, nil, { inherit = true, include_hidden = false }):await())
        t.assertEquals(#value, 3)
        t.assertEquals({ value[1].name, value[2].name, value[3].name }, { "LOCAL", "MASK", "Z" })
        t.assertEquals(value[2].state, "removed")
        t.assertTrue(value[3].inherited)
        t.assertTrue(state.calls[7].grouped)
    end)
end

function M.test_removal_verification_is_bounded_grouped_and_rejects_collisions()
    fixture(function(state, run)
        local rows = {}
        for index = 1, 129 do
            rows[index] = "unset A" .. index .. ";\n"
        end
        state.outputs = { table.concat(rows), "", table.concat(rows, "", 1, 128), rows[129] }
        local value = assert(run("list"):await())
        t.assertEquals(#value, 129)
        t.assertEquals(#state.calls, 4)
        t.assertEquals(#state.calls[3].commands, 128)
        t.assertEquals(#state.calls[4].commands, 1)
        state.outputs = {
            "unset A;\nunset B;\n",
            "",
            { stdout = "", stderr = "unknown variable: A\n", exit_code = 1, signal = 0 },
        }
        local result, err = run("list"):await()
        t.assertNil(result)
        err = assert(err)
        t.assertEquals(err.code, "inconsistent")
        t.assertEquals(err.cause.partial.exit_code, 1)
        t.assertEquals(err.cause.partial.stderr, "unknown variable: A\n")
        state.outputs = { "unset A;\n", "", "unset B;\n" }
        result, err = run("list"):await()
        t.assertNil(result)
        t.assertEquals(assert(err).code, "inconsistent")
    end)
end

function M.test_mutations_are_literal_copied_and_distinguish_unset_from_remove()
    fixture(function(state, run)
        local options = { hidden = true, process = { timeout = 20 } }
        local pending = run("set", "A", "literal;\n\255$HOME", options)
        options.hidden, options.process.timeout = false, 99
        t.assertTrue(pending:await())
        t.assertEquals(
            state.calls[1].commands[1],
            { "set-environment", "-t", "$2", "-h", "--", "A", "literal;\n\255$HOME" }
        )
        t.assertEquals(state.calls[1].options.timeout, 20)
        t.assertTrue(run("unset", "A"):await())
        t.assertTrue(run("remove", "A"):await())
        t.assertEquals(
            state.calls[2].commands[1],
            { "set-environment", "-t", "$2", "-u", "--", "A" }
        )
        t.assertEquals(
            state.calls[3].commands[1],
            { "set-environment", "-t", "$2", "-r", "--", "A" }
        )
    end)
end

function M.test_invalid_names_options_scope_and_values_fail_before_io()
    fixture(function(state, run)
        for _, attempt in ipairs({
            { "get", "bad-name", nil, nil, "unsupported_name" },
            { "set", "A", "x\000", nil, "invalid_argument" },
            { "set", "A", "x", { inherit = true }, "invalid_options" },
            { "get", "A", nil, false, "invalid_options" },
            { "get", "A", nil, { hidden = true }, "invalid_options" },
            { "get", "A", nil, { process = { env = {} } }, "invalid_options" },
            { "get", "A", nil, { scope = "global" }, "invalid_scope" },
            { "list", nil, nil, { process = { max_output_bytes = 1048577 } }, "invalid_options" },
            {
                "set",
                "A",
                "x",
                setmetatable({}, {
                    __index = function()
                        error("caller hook ran")
                    end,
                }),
                "invalid_options",
            },
        }) do
            local value, err = run(attempt[1], attempt[2], attempt[3], attempt[4]):await()
            t.assertNil(value)
            err = assert(err)
            t.assertEquals(err.code, attempt[5])
            t.assertEquals(err.effect, "not_sent")
        end
        t.assertEquals(#state.calls, 0)
    end)
    fixture(function(state, run)
        local value, err = run("get", "A"):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_scope")
        t.assertEquals(#state.calls, 0)
    end, nil, "pane")
end

function M.test_cancellation_and_postflight_generation_preserve_effects()
    fixture(function(state, run, generation)
        local pending = run("set", "A", "x")
        pending:cancel()
        local _, err = pending:await()
        t.assertEquals(assert(err).effect, "not_sent")
        t.assertEquals(#state.calls, 0)
        local stage = "cancel"
        state.before = function()
            if stage == "cancel" then
                pending:cancel()
            else
                identity.invalidate(generation, "test")
            end
        end
        pending = run("set", "A", "x")
        _, err = pending:await()
        t.assertEquals(assert(err).effect, "unknown")
        stage = "invalidate"
        local value
        value, err = run("set", "A", "x"):await()
        t.assertNil(value)
        err = assert(err)
        t.assertEquals(err.code, "stale_generation")
        t.assertEquals(err.effect, "completed")
        t.assertEquals(#state.calls, 2)
    end)
end

function M.test_parent_holds_decoded_and_raw_output_through_callback_delivery()
    fixture(function(state, run)
        state.outputs = { 'A="12345"; export A;\n' }
        local pending = run("get", "A")
        pending:on_complete(function(value)
            t.assertEquals(value.value, "12345")
            t.assertTrue(state.runtime:stats().bytes >= 128 + #"A" + 5 + #'A="12345"; export A;\n')
        end)
        t.assertEquals(assert(pending:await()).value, "12345")
    end)
    fixture(function(state, run)
        local pending = run("set", "A", string.rep("x", 200))
        local value, err = pending:await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "queue_full")
        t.assertEquals(#state.calls, 0)
    end, { max_bytes = 100 })
end

function M.test_aggregate_wire_and_decoded_limits_fail_without_publishing_partial_records()
    fixture(function(state, run)
        local value = string.rep("x", 600000)
        state.outputs = { 'A="' .. value .. '"; export A;\n', 'B="' .. value .. '"; export B;\n' }
        local result, err = run("list"):await()
        t.assertNil(result)
        err = assert(err)
        t.assertEquals(err.code, "frame_limit")
        t.assertEquals(err.effect, "completed")
        t.assertNil(err.partial)
        t.assertEquals(#state.calls, 2)
    end)
    fixture(function(state, run)
        state.outputs = { 'A="x"; export A;\n' }
        local result, err = run("get", "A"):await()
        t.assertNil(result)
        t.assertEquals(assert(err).code, "queue_full")
        t.assertEquals(#state.calls, 1)
    end, { max_bytes = 100 })
    fixture(function(state, run)
        state.outputs = { "unset H;\n", "unset H;\n" }
        local result, err = run("list"):await()
        t.assertNil(result)
        t.assertEquals(assert(err).code, "inconsistent")
        t.assertEquals(#state.calls, 2)
    end)
end

return M
