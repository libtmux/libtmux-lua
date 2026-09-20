local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local errors = require("libtmux._internal.error")
local available, buffer = pcall(require, "libtmux._internal.buffer")
local M = {}

local function fixture(body, kind, version, limits)
    t.assertTrue(available, "typed buffer operations are missing")
    local driver = drivers.new()
    local rt = runtimes.new(driver, limits)
    version = version or "3.7c"
    local generation = assert(identity.generation({
        pid = "1",
        started = "2",
        version = version,
        socket = "/owned/socket",
    }))
    local state = { runtime = rt, version = version, calls = {} }
    state.result = { stdout = "", stderr = "", exit_code = 0, signal = 0 }
    state.bound = {
        generation = function()
            local evidence, err = identity.evidence(generation)
            return evidence and generation, err
        end,
        execute = function(_, argv, options)
            state.calls[#state.calls + 1] = { argv = argv, options = options }
            if state.execute then
                return state.execute()
            end
            return rt:_operation(function(_, request)
                if state.before then
                    state.before()
                end
                assert(request:_retain(#state.result.stdout + #state.result.stderr))
                if state.failure then
                    return nil, state.failure
                end
                return state.result
            end)
        end,
    }
    local owned
    if kind then
        local reference =
            { kind = kind, id = kind == "pane" and "%3" or "$2", generation = generation }
        owned = assert(identity.bind(generation, reference))
        reference.id = "%999"
    end
    local function run(action, name, data, options)
        return buffer.run(state, owned, action, name, data, options)
    end
    local root = rt:start(function()
        return body(state, run, generation, driver)
    end)
    driver:drain()
    local _, err = root:result()
    t.assertNil(err)
    t.assertTrue(root:is_retired())
    t.assertEquals(rt:stats().bytes, 0)
    t.assertEquals(rt:stats().active, 0)
end

local function rejected(request, code)
    local value, err = request:await()
    t.assertNil(value)
    err = assert(err)
    t.assertEquals(err.code, code)
    t.assertEquals(err.effect, "not_sent")
end

function M.test_binary_set_and_show_preserve_nul_and_explicit_text_conversion()
    fixture(function(state, run)
        local pieces = {}
        for byte = 0, 255 do
            pieces[#pieces + 1] = string.char(byte)
        end
        local bytes = table.concat(pieces) .. "\n\n"
        local options = { process = { timeout = 20 } }
        local pending = run("set", "-literal#{pid};λ雪", bytes, options)
        options.process.timeout = 99
        t.assertTrue(pending:await())
        t.assertEquals(state.calls[1].argv, { "load-buffer", "-b", "-literal#{pid};λ雪", "-" })
        t.assertEquals(state.calls[1].options.stdin, bytes)
        t.assertEquals(state.calls[1].options.timeout, 20)
        t.assertEquals(state.calls[1].options.max_output_bytes, 1048576)
        state.result.stdout = bytes
        local result = assert(run("show", "-literal#{pid};λ雪"):await())
        t.assertEquals(result.bytes, bytes)
        t.assertEquals(result.name, "-literal#{pid};λ雪")
        local value, err = result:text()
        t.assertNil(value)
        err = assert(err)
        t.assertEquals(err.code, "invalid_utf8")
        t.assertEquals(err.effect, "completed")
        state.result.stdout = "\000λ雪\r\n"
        result = assert(run("show", "raw\255\n\\name"):await())
        t.assertEquals(result:text(), state.result.stdout)
        t.assertTrue(run("delete", "raw\255\n\\name"):await())
        t.assertEquals(state.calls[4].argv, { "delete-buffer", "-b", "raw\255\n\\name" })
    end)
end

function M.test_paste_modes_are_literal_and_gated_by_exact_daemon_release()
    for _, version in ipairs({
        "3.2a",
        "3.3",
        "3.3a",
        "3.4",
        "3.5",
        "3.5a",
        "3.6",
        "3.6a",
        "3.6b",
        "3.7",
        "3.7a",
        "3.7b",
        "3.7c",
    }) do
        fixture(function(state, run)
            t.assertTrue(run("paste", "A"):await())
            t.assertEquals(state.calls[1].argv, { "paste-buffer", "-b", "A", "-t", "%3" })
            local options =
                { bytes = "raw", linefeed_separator = true, bracket = true, delete_after = true }
            local pending = run("paste", "literal#{pid};", nil, options)
            options.bytes, options.delete_after = "native", false
            t.assertTrue(pending:await())
            local argv = { "paste-buffer", "-b", "literal#{pid};", "-t", "%3" }
            if version:match("^3%.7") then
                argv[#argv + 1] = "-S"
            end
            argv[#argv + 1], argv[#argv + 2], argv[#argv + 3] = "-r", "-p", "-d"
            t.assertEquals(state.calls[2].argv, argv)
            t.assertTrue(run("paste", "A", nil, { separator = "" }):await())
            t.assertEquals(state.calls[3].argv, { "paste-buffer", "-b", "A", "-t", "%3", "-s", "" })
        end, "pane", version)
    end
    fixture(function(state, run)
        rejected(run("paste", "A", nil, { bytes = "raw" }), "unsupported_version")
        t.assertEquals(#state.calls, 0)
    end, "pane", "3.8")
end

function M.test_delete_refuses_releases_that_fall_back_to_another_buffer()
    for _, version in ipairs({ "3.2a", "3.3", "3.3a" }) do
        fixture(function(state, run)
            rejected(run("delete", "missing"), "unsupported")
            t.assertEquals(#state.calls, 0)
        end, nil, version)
    end
end

function M.test_invalid_options_names_values_and_scope_fail_before_io()
    fixture(function(state, run)
        for _, name in ipairs({
            "",
            "nul\000",
            "line\n",
            "back\\slash",
            "\255",
            "\192\128",
            "del\127",
            string.rep("x", 4097),
        }) do
            rejected(run("set", name, "data"), "unsupported_name")
        end
        for _, data in ipairs({ "", false, string.rep("x", 1048577) }) do
            rejected(run("set", "A", data), "invalid_argument")
        end
        rejected(run("show", "nul\000"), "invalid_argument")
        rejected(run("delete", "A", "extra"), "invalid_argument")
        rejected(run("set", "A", "x", { append = true }), "invalid_options")
        rejected(run("set", "A", "x", { process = { stdin = "override" } }), "invalid_options")
        rejected(
            run("show", "A", nil, { process = { max_output_bytes = 1048577 } }),
            "invalid_options"
        )
        rejected(run("show", "A", nil, false), "invalid_options")
        local touched = false
        local mt = {
            __index = function()
                touched = true
                error("caller hook ran")
            end,
        }
        rejected(run("set", "A", "x", setmetatable({}, mt)), "invalid_options")
        rejected(run("show", "A", nil, { process = setmetatable({}, mt) }), "invalid_options")
        rejected(run("paste", "A"), "invalid_target")
        t.assertFalse(touched)
        t.assertEquals(#state.calls, 0)
    end)
    fixture(function(state, run)
        rejected(run("set", "A", "x"), "invalid_target")
        local other = assert(
            identity.generation({ pid = "7", started = "8", version = "3.7c", socket = "other" })
        )
        local foreign =
            assert(identity.bind(other, { kind = "pane", id = "%3", generation = other }))
        rejected(buffer.run(state, foreign, "paste", "A"), "stale_generation")
        for _, options in ipairs({
            { bytes = "typo" },
            { bracket = 1 },
            { delete_after = "yes" },
            { separator = "x", linefeed_separator = true },
            { separator = "x", linefeed_separator = false },
            { separator = "x\000" },
            { process = { cwd = "/tmp" } },
        }) do
            rejected(run("paste", "A", nil, options), "invalid_options")
        end
        t.assertEquals(#state.calls, 0)
    end, "pane")
    fixture(function(state, run)
        rejected(run("paste", "A"), "invalid_target")
        t.assertEquals(#state.calls, 0)
    end, "session")
end

function M.test_admission_stale_generation_and_completed_errors_preserve_receipts()
    fixture(function(state, run, generation)
        state.runtime._limits.max_bytes = 32
        rejected(run("set", "A", string.rep("x", 64)), "queue_full")
        state.runtime._limits.max_bytes = 10000
        t.assertEquals(#state.calls, 0)
        state.failure = errors.new(
            "exit_failed",
            "missing named buffer",
            { effect = "completed", partial = state.result }
        )
        local result, err = run("show", "A"):await()
        t.assertNil(result)
        t.assertIs(err, state.failure)
        state.failure = nil
        state.before = function()
            identity.invalidate(generation, "test")
        end
        result, err = run("delete", "A"):await()
        t.assertNil(result)
        err = assert(err)
        t.assertEquals(err.code, "stale_generation")
        t.assertEquals(err.effect, "completed")
        t.assertIs(err.partial, state.result)
        rejected(run("show", "A"), "stale_generation")
        t.assertEquals(#state.calls, 2)
    end)
    fixture(function(state, run)
        local pending = run("set", "A", "x")
        state.closed = true
        rejected(pending, "closed")
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_cancellation_joins_owned_retirement_and_never_retries()
    fixture(function(state, run, _, driver)
        local pending = run("set", "A", "x")
        pending:cancel()
        rejected(pending, "cancelled")
        t.assertEquals(#state.calls, 0)
        local retired = false
        state.execute = function()
            return state.runtime:_request({
                start = function(_, retire, child)
                    child:_set_effect("unknown")
                    driver.defer(function()
                        pending:cancel()
                        t.assertFalse(pending:is_retired())
                        driver.defer(function()
                            retired = true
                            retire()
                        end)
                    end)
                    return function() end
                end,
            })
        end
        pending = run("set", "A", "\000bytes")
        local result, err = pending:await()
        t.assertNil(result)
        t.assertEquals(assert(err).effect, "unknown")
        t.assertFalse(retired)
        t.assertEquals(#state.calls, 1)
    end)
end

function M.test_raw_output_and_input_remain_bounded_and_retained_through_callbacks()
    fixture(function(state, run)
        state.result.stdout = string.rep("x", 1048576)
        local pending = run("show", "A")
        pending:on_complete(function(value)
            t.assertEquals(#value.bytes, 1048576)
            t.assertTrue(state.runtime:stats().bytes >= 1048576)
        end)
        t.assertEquals(#assert(pending:await()).bytes, 1048576)
        state.result.stdout = ""
        t.assertTrue(run("set", "A", string.rep("x", 1048576)):await())
    end)
    fixture(function(state, run)
        state.result.stdout = string.rep("x", 100)
        state.execute = function()
            return state.runtime:_operation(function(_, child)
                assert(child:_retain(#state.result.stdout))
                state.runtime._limits.max_bytes = 80
                return state.result
            end)
        end
        local result, err = run("show", "A"):await()
        t.assertNil(result)
        err = assert(err)
        t.assertEquals(err.code, "queue_full")
        t.assertTrue(err.partial.output_truncated)
        t.assertNil(err.partial.stdout)
    end, nil, nil, { max_bytes = 180 })
end

return M
