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
        value, err = session:copy_mode():await()
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

function M.test_pending_capture_copies_options_and_rejects_ignored_screen_controls()
    fixture(function(state, pane)
        state.output = "\\033[\n"
        ---@type table<string, boolean|integer>
        local options = { pending_escape_sequences = true, escape_nonprintable = true }
        local pending = pane:capture(options)
        options.pending_escape_sequences, options.escape_nonprintable = false, false
        local captured = assert(pending:await())
        t.assertEquals(captured.bytes, "\\033[\n")
        t.assertEquals(state.calls[1].argv, { "capture-pane", "-t", "%8", "-p", "-C", "-P" })
        for _, incompatible in ipairs({
            "history_lines",
            "start_line",
            "end_line",
            "alternate_screen",
            "mode_screen",
            "join_lines",
            "preserve_spaces",
            "escape_sequences",
            "trim_empty_cells",
            "hyperlinks_only",
            "line_numbers",
            "line_flags",
            "ignore_missing_alternate",
        }) do
            options = { pending_escape_sequences = true }
            options[incompatible] = (
                incompatible == "history_lines"
                or incompatible == "start_line"
                or incompatible == "end_line"
            )
                    and 0
                or true
            local value, err = pane:capture(options):await()
            t.assertNil(value)
            t.assertEquals(assert(err).code, "invalid_options")
            t.assertEquals(err.effect, "not_sent")
        end
        t.assertEquals(#state.calls, 1)
        state.output = "\n"
        captured = assert(
            pane:capture({ alternate_screen = true, ignore_missing_alternate = true }):await()
        )
        t.assertEquals(captured.bytes, "\n")
        t.assertEquals(state.calls[2].argv, { "capture-pane", "-t", "%8", "-p", "-a", "-q" })
        local value, err = pane:capture({ ignore_missing_alternate = true }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_options")
        t.assertEquals(#state.calls, 2)
    end)
end

function M.test_capture_hyperlinks_and_line_metadata_require_native_capabilities()
    fixture(function(state, pane)
        state.version = "3.6b"
        for _, option in ipairs({ "hyperlinks_only", "line_numbers", "line_flags" }) do
            local value, err = pane:capture({ [option] = true }):await()
            t.assertNil(value)
            t.assertEquals(assert(err).code, "unsupported")
            t.assertEquals(err.effect, "not_sent")
        end
        t.assertEquals(#state.calls, 0)
        state.version, state.output = "3.7", "-1 H https://example.invalid/\n"
        local captured = assert(pane:capture({
            start_line = "-",
            hyperlinks_only = true,
            line_numbers = true,
            line_flags = true,
        }):await())
        t.assertEquals(captured.bytes, state.output)
        t.assertEquals(state.calls[1].argv, {
            "capture-pane",
            "-t",
            "%8",
            "-p",
            "-S",
            "-",
            "-H",
            "-L",
            "-F",
        })
        for _, option in ipairs({
            "escape_sequences",
            "escape_nonprintable",
            "preserve_spaces",
            "trim_empty_cells",
        }) do
            local value, err = pane:capture({ hyperlinks_only = true, [option] = true }):await()
            t.assertNil(value)
            t.assertEquals(assert(err).code, "invalid_options")
        end
        t.assertEquals(#state.calls, 1)
    end)
end

function M.test_clear_history_is_scoped_and_checks_hyperlink_support_before_dispatch()
    fixture(function(state, pane)
        state.version = "3.3a"
        assert(pane:clear_history():await())
        t.assertEquals(state.calls[1].argv, { "clear-history", "-t", "%8" })
        local value, err = pane:clear_history({ clear_hyperlinks = true }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "unsupported")
        t.assertEquals(err.effect, "not_sent")
        state.version = "3.4"
        local options = { clear_hyperlinks = true }
        local pending = pane:clear_history(options)
        options.clear_hyperlinks = false
        assert(pending:await())
        t.assertEquals(state.calls[2].argv, { "clear-history", "-t", "%8", "-H" })
        pending = pane:clear_history()
        pending:cancel()
        value, err = pending:await()
        t.assertNil(value)
        t.assertEquals(assert(err).effect, "not_sent")
        t.assertEquals(#state.calls, 2)
    end)
end

function M.test_named_capture_requires_a_literal_creation_name_and_returns_completion()
    fixture(function(state, pane)
        local options = { history_lines = 20, join_lines = true }
        local pending = pane:capture_to_buffer("literal#{pid};", options)
        options.history_lines = 99
        t.assertTrue(assert(pending:await()))
        t.assertEquals(state.calls[1].argv, {
            "capture-pane",
            "-t",
            "%8",
            "-b",
            "literal#{pid};",
            "-S",
            "-20",
            "-J",
        })
        for _, name in ipairs({
            "",
            "bad\000name",
            "bad\nname",
            "bad\\name",
            "\255",
            string.rep("x", 4097),
        }) do
            local value, err = pane:capture_to_buffer(name):await()
            t.assertNil(value)
            t.assertEquals(assert(err).code, "unsupported_name")
            t.assertEquals(err.effect, "not_sent")
        end
        local value, err = pane:capture_to_buffer("valid", {
            pending_escape_sequences = true,
            history_lines = 1,
        }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_options")
        t.assertEquals(#state.calls, 1)
        assert(pane:capture_to_buffer("pending", { pending_escape_sequences = true }):await())
        t.assertEquals(state.calls[2].argv, { "capture-pane", "-t", "%8", "-b", "pending", "-P" })
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

function M.test_selection_title_and_swap_preserve_literal_private_targets()
    fixture(function(state, pane, generation, entity)
        local other = assert(entity.from_reference(state, {
            kind = "pane",
            id = "%9",
            generation = generation,
        }))
        other.reference = function()
            error("caller method must not run")
        end
        assert(pane:select({ keep_zoom = true }):await())
        assert(pane:set_title("literal#{pane_id};λ"):await())
        local options = { keep_zoom = true }
        local pending = pane:swap(other, options)
        options.select = true
        assert(pending:await())
        t.assertEquals(state.calls[1].argv, { "select-pane", "-t", "%8", "-Z" })
        t.assertEquals(state.calls[2].argv, {
            "select-pane",
            "-t",
            "%8",
            "-T",
            "literal##{pane_id};λ",
        })
        t.assertEquals(state.calls[3].argv, { "swap-pane", "-t", "%9", "-s", "%8", "-d", "-Z" })
        assert(pane:swap(other, { select = true }):await())
        t.assertEquals(state.calls[4].argv, { "swap-pane", "-t", "%9", "-s", "%8" })
        for _, attempt in ipairs({
            function()
                return pane:swap({ reference = other.reference })
            end,
            function()
                return pane:swap(pane)
            end,
            function()
                return pane:swap(other, { select = "no" })
            end,
            function()
                return pane:set_title("\255")
            end,
            function()
                return pane:set_title("bad\000title")
            end,
            function()
                return pane:set_title("line\nnext")
            end,
            function()
                return pane:select({ keep_zoom = 1 })
            end,
        }) do
            local value, err = attempt():await()
            t.assertNil(value)
            t.assertEquals(assert(err).effect, "not_sent")
        end
        t.assertEquals(#state.calls, 4)
    end)
end

function M.test_move_requires_explicit_selection_context_and_validates_geometry()
    fixture(function(state, pane, generation, entity)
        t.assertEquals(type(pane.move_to), "function", "Pane move_to API is missing")
        local other = assert(
            entity.from_reference(state, { kind = "pane", id = "%9", generation = generation })
        )
        local link = assert(entity.from_reference(state, {
            kind = "window_link",
            session_id = "$2",
            window_id = "@3",
            index = 5,
            generation = generation,
        }))
        for _, options in ipairs({
            { select = true },
            { direction = "sideways" },
            { size = 0 },
            { percent = 101 },
            { size = 1, percent = 20 },
            { before = 1 },
            { target_link = other },
            { unknown = true },
        }) do
            local value, err = pane:move_to(other, options):await()
            t.assertNil(value)
            t.assertEquals(assert(err).effect, "not_sent")
        end
        local value, err = pane:move_to(pane):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_target")
        t.assertEquals(#state.calls, 0)
        assert(pane:move_to(other):await())
        t.assertEquals(state.calls[1].argv, { "join-pane", "-s", "%8", "-t", "%9", "-v", "-d" })
        local options = {
            target_link = link,
            select = true,
            direction = "horizontal",
            percent = 30,
            before = true,
            full_size = true,
        }
        local pending = pane:move_to(other, options)
        options.percent = 50
        assert(pending:await())
        local call = state.calls[2].argv
        t.assertEquals(call[4], "$2:5")
        local nested = call[6]:gsub("\\(%d%d%d)", function(part)
            return string.char(tonumber(part, 8))
        end)
        t.assertStrContains(nested, '"if-shell" "-F" "-t" "%9"')
        t.assertStrContains(nested, "#{==:#{pane_id},%9}")
        local mutation = nested:gsub("\\(%d%d%d)", function(part)
            return string.char(tonumber(part, 8))
        end)
        t.assertStrContains(
            mutation,
            '"join-pane" "-s" "%8" "-t" "$2:5.%9" "-h" "-l" "30%" "-b" "-f"'
        )
    end)
end

function M.test_break_requires_owned_context_and_handles_exact_3_7_naming()
    fixture(function(state, pane, generation, entity)
        t.assertEquals(type(pane.break_out), "function", "Pane break_out API is missing")
        local source = assert(entity.from_reference(state, {
            kind = "window_link",
            session_id = "$2",
            window_id = "@3",
            index = 5,
            generation = generation,
        }))
        local session = assert(
            entity.from_reference(state, { kind = "session", id = "$4", generation = generation })
        )
        for _, options in ipairs({
            { name = "" },
            { name = "bad\000" },
            { select = 1 },
            { replace = true },
        }) do
            local value, err = pane:break_out(source, { session = session }, options):await()
            t.assertNil(value)
            t.assertEquals(assert(err).effect, "not_sent")
        end
        local value, err = pane:break_out(pane, { session = session }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_target")
        t.assertEquals(#state.calls, 0)
        for _, version in ipairs({ "3.7", "3.7a" }) do
            state.version = version
            for _, named in ipairs({ false, true }) do
                local options = named and { name = "literal#{pid};" } or {}
                local pending = pane:break_out(source, { session = session, index = 9 }, options)
                options.name = "changed"
                assert(pending:await())
                local argv = state.calls[#state.calls].argv
                t.assertEquals(argv[4], "$2:5")
                local expanded = argv[6]
                for _ = 1, 4 do
                    expanded = expanded:gsub("\\(%d%d%d)", function(part)
                        return string.char(tonumber(part, 8))
                    end)
                end
                t.assertStrContains(expanded, '"break-pane" "-s" "$2:5.%8" "-t" "$4:9" "-d"')
                t.assertEquals(expanded:find("#{window_panes}", 1, true) ~= nil, version == "3.7")
                t.assertEquals(
                    expanded:find("rename-window", 1, true) ~= nil,
                    version == "3.7" and named
                )
                if named then
                    t.assertStrContains(expanded, '"-n" "literal#{pid};"')
                end
            end
        end
    end)
end

function M.test_topology_completion_preserves_effect_when_generation_is_invalidated()
    fixture(function(state, pane, generation)
        state.before = function()
            identity.invalidate(generation)
        end
        local value, err = pane:select():await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "stale_generation")
        t.assertEquals(err.effect, "completed")
        t.assertEquals(err.partial.stdout, state.output)
        t.assertEquals(#state.calls, 1)
    end)
end

function M.test_empty_title_rejects_exact_3_7_native_silent_noop()
    fixture(function(state, pane)
        state.version = "3.7"
        local value, err = pane:set_title(""):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "unsupported")
        t.assertEquals(err.effect, "not_sent")
        t.assertEquals(#state.calls, 0)
        state.version = "3.7a"
        assert(pane:set_title(""):await())
        t.assertEquals(state.calls[1].argv, { "select-pane", "-t", "%8", "-T", "" })
    end)
end

return M
