local t = require("luaunit")
local runtime = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local errors = require("libtmux._internal.error")
local available = pcall(require, "libtmux._internal.pane")
local M = {}

local function fixture(body)
    t.assertTrue(available, "typed Pane operations are missing")
    local driver = drivers.new()
    local rt = runtime.new(driver)
    local generation = assert(identity.generation({
        pid = "1",
        started = "2",
        version = "3.7c",
        socket = "/owned/socket",
    }))
    local state = { runtime = rt, version = "3.7c", calls = {}, output = "line  \n\n" }
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
                local result = { stdout = state.output, stderr = "", exit_code = 0, signal = 0 }
                assert(request:_retain(#result.stdout))
                if state.failure then
                    return nil, state.failure
                end
                return result
            end)
        end,
    }
    local entity = require("libtmux._internal.entity")
    local pane =
        assert(entity.from_reference(state, { kind = "pane", id = "%8", generation = generation }))
    local root = rt:start(function()
        return body(state, pane, generation, entity)
    end)
    driver:drain()
    local _, err = root:result()
    t.assertNil(err)
    t.assertTrue(root:is_retired())
    t.assertEquals(rt:stats().bytes, 0)
end

function M.test_capture_preserves_rendered_bytes_and_explicit_text_validation()
    fixture(function(state, pane)
        local exposed = pane:reference()
        exposed.id = "%999"
        local result = assert(pane:capture({ history_lines = 20, join_lines = true }):await())
        t.assertEquals(result.bytes, "line  \n\n")
        t.assertEquals(result:text(), result.bytes)
        t.assertEquals(state.calls[1].argv, { "capture-pane", "-t", "%8", "-p", "-S", "-20", "-J" })
        for _, value in ipairs({
            "\255",
            "\192\128",
            "\237\160\128",
            "\244\144\128\128",
            "\226\130",
        }) do
            state.output = value
            result = assert(pane:capture():await())
            t.assertEquals(result.bytes, value)
            local text, err = result:text()
            t.assertNil(text)
            t.assertEquals(assert(err).code, "invalid_utf8")
            t.assertEquals(err.effect, "completed")
        end
        state.output = "\000λ雪\240\159\152\128\r\n"
        result = assert(pane:capture():await())
        t.assertEquals(result:text(), state.output)
    end)
end

function M.test_input_is_copied_literal_and_enter_is_only_an_explicit_key()
    fixture(function(state, pane)
        local text = "literal;#{pid}\\\nλ"
        assert(pane:send_text(text):await())
        t.assertEquals(state.calls[1].argv, { "send-keys", "-t", "%8", "-l", "--", text })
        local keys, options = { "C-c", "Enter" }, { repeat_count = 2 }
        local pending = pane:send_keys(keys, options)
        keys[1], options.repeat_count = "changed", 99
        assert(pending:await())
        t.assertEquals(
            state.calls[2].argv,
            { "send-keys", "-t", "%8", "-N", "2", "--", "C-c", "Enter" }
        )
        local cases = {
            function()
                return pane:send_keys({ "Enetr" })
            end,
            function()
                return pane:send_keys({ [1] = "Enter", [3] = "Tab" })
            end,
            function()
                return pane:send_keys(setmetatable({}, {
                    __len = function()
                        error("called")
                    end,
                }))
            end,
            function()
                return pane:send_text("bad\000text")
            end,
            function()
                return pane:send_text("\255")
            end,
            function()
                return pane:send_keys({ "Enter" }, { repeat_count = 0 })
            end,
            function()
                return pane:capture(false)
            end,
            function()
                return pane:kill({ process = { stdin = "not allowed" } })
            end,
        }
        for _, attempt in ipairs(cases) do
            local value, err = attempt():await()
            t.assertNil(value)
            t.assertEquals(assert(err).effect, "not_sent")
        end
        t.assertEquals(#state.calls, 2)
        local value, err = pane:send_keys({ "MouseDown1Pane" }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "unsupported")
        value, err = pane:copy_command("page-up", false):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_argument")
    end)
end

function M.test_cancelled_input_never_retries_and_preserves_possible_effects()
    fixture(function(state, pane)
        local pending = pane:send_text("before")
        pending:cancel()
        local value, err = pending:await()
        t.assertNil(value)
        t.assertEquals(assert(err).effect, "not_sent")
        t.assertEquals(#state.calls, 0)
        state.before = function()
            pending:cancel()
        end
        pending = pane:send_text("during")
        value, err = pending:await()
        t.assertNil(value)
        t.assertEquals(assert(err).effect, "unknown")
        t.assertEquals(#state.calls, 1)
    end)
end

function M.test_copy_actions_resize_and_kill_have_explicit_targets_and_scope()
    fixture(function(state, pane, generation, entity)
        assert(pane:copy_mode({ page_up = true }):await())
        assert(pane:copy_command("page-up", {}, { repeat_count = 3 }):await())
        assert(pane:resize({ direction = "left", amount = 4 }):await())
        assert(pane:kill():await())
        t.assertEquals(state.calls[1].argv, { "copy-mode", "-t", "%8", "-u" })
        t.assertEquals(
            state.calls[2].argv,
            { "send-keys", "-t", "%8", "-X", "-N", "3", "--", "page-up" }
        )
        t.assertEquals(state.calls[3].argv, { "resize-pane", "-t", "%8", "-L", "4" })
        t.assertEquals(state.calls[4].argv, { "kill-pane", "-t", "%8" })
        local value, err = pane:copy_command("page-upp"):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_copy_command")
        value, err = pane:copy_command("copy-pipe", { "shell program" }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "unsupported")
        value, err = pane:copy_command("page-up", { "extra" }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).effect, "not_sent")
        value, err = pane:resize({ width = 10, direction = "left" }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_options")
        local session = assert(
            entity.from_reference(state, { kind = "session", id = "$1", generation = generation })
        )
        value, err = session:kill():await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_target")
        t.assertEquals(#state.calls, 4)
    end)
end

function M.test_capture_capabilities_fail_before_dispatch_and_ranges_are_explicit()
    fixture(function(state, pane)
        state.version = "3.2a"
        for _, options in ipairs({
            { mode_screen = true },
            { trim_empty_cells = true },
            { start_line = "#{pid}" },
            { history_lines = 2, start_line = 0 },
        }) do
            local value, err = pane:capture(options):await()
            t.assertNil(value)
            t.assertEquals(assert(err).effect, "not_sent")
        end
        t.assertEquals(#state.calls, 0)
        state.version = "3.6"
        assert(pane:capture({
            mode_screen = true,
            trim_empty_cells = true,
            start_line = "-",
            end_line = 0,
        }):await())
        t.assertEquals(
            state.calls[1].argv,
            { "capture-pane", "-t", "%8", "-p", "-S", "-", "-E", "0", "-M", "-T" }
        )
    end)
end

function M.test_byte_admission_and_generation_precede_effects()
    fixture(function(state, pane, generation)
        state.runtime._limits.max_bytes = 8
        local value, err = pane:send_text(string.rep("x", 64)):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "queue_full")
        t.assertEquals(err.effect, "not_sent")
        state.runtime._limits.max_bytes = 10000
        local pending = pane:kill()
        identity.invalidate(generation)
        value, err = pending:await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "stale_generation")
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_result_callbacks_retain_bytes_and_native_failures_remain_typed()
    fixture(function(state, pane)
        local pending = pane:capture()
        pending:on_complete(function(value)
            t.assertEquals(value.bytes, state.output)
            t.assertTrue(state.runtime:stats().bytes >= #state.output)
        end)
        assert(pending:await())
        state.failure = errors.new("exit_failed", "native failure", {
            effect = "completed",
            partial = { stdout = "partial", stderr = "native", exit_code = 1, signal = 0 },
        })
        local value, err = pane:kill():await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "exit_failed")
        t.assertEquals(err.partial.stderr, "native")
        t.assertEquals(err.effect, "completed")
    end)
end

function M.test_respawn_reuses_literal_launch_arguments_without_replacing_pane_identity()
    fixture(function(state, pane)
        assert(
            pane:respawn({ kill = true, argv = { "/bin/cat" }, environment = { VALUE = "#{pid}" } })
                :await()
        )
        t.assertEquals(state.calls[1].argv, {
            "respawn-pane",
            "-t",
            "%8",
            "-k",
            "-e",
            "VALUE=#{pid}",
            "--",
            "/usr/bin/env",
            "--",
            "/bin/cat",
        })
        t.assertEquals(pane:reference().id, "%8")
        assert(pane:respawn():await())
        t.assertEquals(state.calls[2].argv, { "respawn-pane", "-t", "%8", "--" })
        local value, err = pane:respawn({ argv = { "/bin/cat" }, shell = "exec cat" }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).effect, "not_sent")
        t.assertEquals(#state.calls, 2)
    end)
end

function M.test_private_inspection_ignores_overwritten_methods_and_rejects_foreign_handles()
    fixture(function(state, pane, generation, entity)
        pane.reference = function()
            error("caller method must not run")
        end
        local ref = assert(entity.inspect(state, pane, "pane"))
        ref.id = "%999"
        t.assertEquals(assert(entity.inspect(state, pane, "pane")).id, "%8")
        local value, err = entity.inspect({}, pane, "pane")
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_target")
        value, err = entity.inspect(state, {}, "pane")
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_target")
        value, err = entity.inspect(state, pane, "session")
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_target")
        identity.invalidate(generation)
        value, err = entity.inspect(state, pane, "pane")
        t.assertNil(value)
        t.assertEquals(assert(err).code, "stale_generation")
    end)
end

return M
