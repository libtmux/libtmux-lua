local t = require("luaunit")
local runtime = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local available, domain = pcall(require, "libtmux._internal.domain")
local M = {}

local function fixture(body)
    t.assertTrue(available, "domain creation is missing")
    local driver = drivers.new()
    local rt = runtime.new(driver)
    local generation = assert(identity.generation({
        pid = "1",
        started = "2",
        version = "3.7c",
        socket = "/owned/socket",
    }))
    local state = { runtime = rt, version = "3.7c", calls = {} }
    state.bound = {
        generation = function()
            local value, err = identity.evidence(generation)
            return value and generation, err
        end,
        execute = function(_, argv, options)
            state.calls[#state.calls + 1] = { argv = argv, options = options }
            return rt:_operation(function(_, request)
                if state.before then
                    state.before()
                end
                local format
                for index, value in ipairs(argv) do
                    if value == "-F" then
                        format = argv[index + 1]
                    end
                end
                local values =
                    { session_id = "$1", window_id = "@2", pane_id = "%3", window_index = "4" }
                for index, value in ipairs(argv) do
                    if argv[1] == "new-window" and value == "-t" then
                        values.session_id = argv[index + 1]:match("^(%$%d+):")
                    end
                end
                local output = state.output or format:gsub("#{q:([^}]+)}", values) .. "\n"
                assert(request:_retain(#output))
                return { stdout = output, stderr = "", exit_code = 0, signal = 0 }
            end)
        end,
    }
    local root = rt:start(function()
        return body(state, generation)
    end)
    driver:drain()
    local _, err = root:result()
    t.assertNil(err)
    t.assertTrue(root:is_retired())
end

local function wrap(_, ref)
    return ref
end

local function argument(argv, flag)
    for index, value in ipairs(argv) do
        if value == flag then
            return argv[index + 1]
        end
    end
end

function M.test_creation_copies_data_and_returns_all_actual_context_ids()
    fixture(function(state, generation)
        local options = {
            name = "literal-#{pid}",
            window_name = "#{window_id}",
            argv = { "/bin/cat" },
            environment = { TERM_VALUE = "#{pid};$(x)" },
            width = 120,
            height = 40,
        }
        local pending = domain.create(state, nil, "session", options, wrap)
        options.name, options.argv[1], options.environment.TERM_VALUE =
            "changed", "/other", "changed"
        local created = assert(pending:await())
        t.assertEquals(created.session.id, "$1")
        t.assertEquals(created.window.id, "@2")
        t.assertEquals(created.pane.id, "%3")
        t.assertEquals(created.window_link.index, 4)
        t.assertTrue(rawequal(created.pane.generation, generation))
        t.assertEquals(created.created, { "session", "window", "pane", "window_link" })
        local argv = state.calls[1].argv
        t.assertEquals(argument(argv, "-s"), "literal-##{pid}")
        t.assertEquals(argument(argv, "-n"), "##{window_id}")
        t.assertEquals(argument(argv, "-e"), "TERM_VALUE=#{pid};$(x)")
        t.assertEquals(
            { argv[#argv - 2], argv[#argv - 1], argv[#argv] },
            { "/usr/bin/env", "--", "/bin/cat" }
        )
    end)
end

function M.test_invalid_whole_input_dispatches_nothing()
    fixture(function(state)
        local cases = {
            { argv = { "/bin/cat" }, shell = "echo no" },
            { argv = { [1] = "/bin/cat", [3] = "hole" } },
            { argv = { "/owned/program=value" } },
            { environment = { OK = "yes", BAD = false } },
            { name = "bad:name" },
            { width = 0 },
            { cwd = "relative" },
            { unsupported = true },
            { process = { unsupported = true } },
            { process = { timeout = false } },
            { process = { timeout = 0 / 0 } },
            { process = { deadline = math.huge } },
        }
        for _, options in ipairs(cases) do
            local value, err = domain.create(state, nil, "session", options, wrap):await()
            t.assertNil(value)
            t.assertEquals(err.effect, "not_sent")
        end
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_parent_identity_selects_exact_context_and_rejects_wrong_kind()
    fixture(function(state, generation)
        local parent = assert(
            identity.bind(generation, { generation = generation, kind = "session", id = "$8" })
        )
        local created = assert(
            domain
                .create(state, parent, "window", { index = 9, shell = "exec /bin/cat" }, wrap)
                :await()
        )
        t.assertEquals(argument(state.calls[1].argv, "-t"), "$8:9")
        t.assertEquals(created.created, { "window", "pane", "window_link" })
        local value, err = domain.create(state, parent, "pane", {}, wrap):await()
        t.assertNil(value)
        t.assertEquals(err.code, "invalid_target")
        t.assertEquals(#state.calls, 1)
        state.output = "LQ1\r$a;\\$99;@2;%3;4;.\n"
        value, err = domain.create(state, parent, "window", {}, wrap):await()
        t.assertNil(value)
        t.assertEquals(err.code, "invalid_result")
        t.assertEquals(err.effect, "completed")
        t.assertEquals(err.partial.stdout, state.output)
    end)
end

function M.test_stale_or_closed_parent_and_invalid_input_bytes_precede_effects()
    fixture(function(state, generation)
        state.runtime._limits.max_bytes = 8
        local value, err =
            domain.create(state, nil, "session", { name = string.rep("x", 64) }, wrap):await()
        t.assertNil(value)
        t.assertEquals(err.code, "queue_full")
        t.assertEquals(err.effect, "not_sent")
        state.runtime._limits.max_bytes = 10000
        identity.invalidate(generation)
        value, err = domain.create(state, nil, "session", {}, wrap):await()
        t.assertNil(value)
        t.assertEquals(err.code, "stale_generation")
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_malformed_creation_reply_keeps_completed_effect_and_output_budget()
    fixture(function(state)
        state.output = "unexpected creation reply\n"
        local pending = domain.create(state, nil, "session", {}, wrap)
        pending:on_complete(function(value, err)
            t.assertNil(value)
            t.assertEquals(err.code, "invalid_result")
            t.assertEquals(err.effect, "completed")
            t.assertEquals(err.partial.stdout, state.output)
            t.assertTrue(state.runtime:stats().bytes >= #state.output)
        end)
        local _, err = pending:await()
        t.assertEquals(err.code, "invalid_result")
    end)
end

return M
