local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local available, settings = pcall(require, "libtmux._internal.settings")
local M = {}

local function fixture(kind, version, body)
    t.assertTrue(available, "typed settings operations are missing")
    local driver = drivers.new()
    local rt = runtimes.new(driver)
    local generation =
        assert(identity.generation({ pid = "1", started = "2", socket = "s", version = version }))
    local state = { runtime = rt, version = version, calls = {}, outputs = {} }
    local function result(commands)
        state.calls[#state.calls + 1] = commands
        return rt:_operation(function()
            if state.before then
                state.before()
            end
            return {
                stdout = table.remove(state.outputs, 1) or "",
                stderr = "",
                exit_code = 0,
                signal = 0,
            }
        end)
    end
    state.bound = {
        generation = function()
            local evidence, err = identity.evidence(generation)
            return evidence and generation, err
        end,
        execute = function(_, argv)
            return result({ argv })
        end,
        group = function(_, commands)
            return result(commands)
        end,
    }
    local owned
    if kind then
        owned = assert(identity.bind(generation, {
            kind = kind,
            generation = generation,
            id = ({ session = "$2", window = "@3", pane = "%4" })[kind],
        }))
    end
    local function operation(family, action, name, value, options)
        return settings.run(state, owned, family, action, name, value, options)
    end
    local root = rt:start(function()
        return body(state, operation, generation)
    end)
    driver:drain()
    local _, err = root:result()
    t.assertNil(err)
    t.assertTrue(root:is_retired())
    t.assertEquals(rt:stats().bytes, 0)
end

function M.test_native_types_false_absence_and_sparse_array_inheritance()
    fixture("session", "3.7c", function(state, run)
        state.outputs = { "", "mouse* off\n" }
        local value = assert(run("option", "get", "mouse"):await())
        t.assertTrue(value.present)
        t.assertTrue(value.inherited)
        t.assertEquals(value.value, false)
        state.outputs = { "status-format[0] one\nstatus-format[9] 'two\"'\n" }
        value = assert(run("option", "get", "status-format", nil, { inherit = false }):await())
        t.assertEquals(
            value.entries,
            { { index = 0, value = "one" }, { index = 9, value = 'two"' } }
        )
        state.outputs = { "status-format\n" }
        value = assert(run("option", "get", "status-format"):await())
        t.assertTrue(value.present)
        t.assertFalse(value.inherited)
        t.assertEquals(value.entries, {})
        state.outputs = { "" }
        value = assert(run("option", "get", "status-format", nil, { inherit = false }):await())
        t.assertFalse(value.present)
        t.assertNil(value.entries)
    end)
end

function M.test_wrong_scope_and_version_specific_type_fail_before_io()
    fixture("pane", "3.7c", function(state, run)
        local value, err = run("option", "set", "mouse", false):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_scope")
        t.assertEquals(#state.calls, 0)
    end)
    fixture("window", "3.2a", function(state, run)
        local value, err = run("option", "set", "allow-passthrough", "all"):await()
        t.assertNil(value)
        t.assertEquals(assert(err).effect, "not_sent")
        t.assertEquals(#state.calls, 0)
    end)
    fixture("session", "3.7c", function(state, run)
        for _, case in ipairs({
            { "mouse", "off" },
            { "history-limit", 1.5 },
            { "history-limit", -1 },
            { "status", "typo" },
            { "status-left", "nul\000" },
        }) do
            local value, err = run("option", "set", case[1], case[2]):await()
            t.assertNil(value)
            t.assertEquals(assert(err).effect, "not_sent")
        end
        t.assertEquals(#state.calls, 0)
        assert(run("option", "set", "mouse", false):await())
        t.assertEquals(state.calls[1][1], { "set-option", "-t", "$2", "--", "mouse", "off" })
    end)
end

function M.test_hook_programs_are_copied_and_execution_has_no_storage_flags()
    fixture("session", "3.7c", function(state, run)
        local input = { commands = { { "display-message", "-p", "literal;$#{pid}" } } }
        local request = run("hook", "set", "session-renamed", input, { index = 4 })
        input.commands[1][3] = "changed"
        assert(request:await())
        local argv = state.calls[1][1]
        t.assertEquals(argv[1], "set-hook")
        t.assertEquals(argv[#argv - 1], "session-renamed[4]")
        t.assertStrContains(argv[#argv], "\\154\\151\\164\\145\\162\\141\\154")
        assert(run("hook", "run", "session-renamed"):await())
        t.assertEquals(state.calls[2][1], { "set-hook", "-R", "-t", "$2", "--", "session-renamed" })
        local value, err = run("hook", "run", "session-renamed", nil, { index = 0 }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).effect, "not_sent")
        value, err =
            run("hook", "set", "default-client-command", { source = "display-message x" }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_hook")
        state.outputs = {
            "session-renamed[0] display-message -p first\n"
                .. "session-renamed[7] display-message -p last\n",
        }
        value = assert(run("hook", "get", "session-renamed", nil, { index = 7 }):await())
        t.assertEquals(value.entries, { { index = 7, source = "display-message -p last" } })
        t.assertEquals(state.calls[3][1][#state.calls[3][1]], "session-renamed")
    end)
end

function M.test_generation_change_after_read_rejects_publication()
    fixture("session", "3.7c", function(state, run, generation)
        state.outputs = { "mouse off\n" }
        state.before = function()
            identity.invalidate(generation, "test")
        end
        local value, err = run("option", "get", "mouse"):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "stale_generation")
        t.assertEquals(err.effect, "completed")
    end)
end

function M.test_malformed_listings_do_not_publish_wrong_scopes_or_conflicting_arrays()
    fixture("session", "3.7c", function(state, run)
        for _, output in ipairs({
            "buffer-limit 5\n",
            "status-format\nstatus-format[0] x\n",
        }) do
            state.outputs = { output }
            local value, err = run("option", "list", nil, nil, { inherit = false }):await()
            t.assertNil(value)
            t.assertEquals(assert(err).code, "invalid_frame")
            t.assertEquals(err.effect, "completed")
        end
    end)
end

function M.test_inherited_listing_bounds_count_all_native_rows()
    fixture("session", "3.7c", function(state, run)
        local rows = {}
        for index = 0, 2099 do
            rows[#rows + 1] = "status-format[" .. index .. "] x\n"
        end
        local output = table.concat(rows)
        state.outputs = { output, output }
        local value, err = run("option", "list"):await()
        t.assertTrue(value == nil, "oversized aggregate listing was published")
        t.assertEquals(assert(err).code, "output_limit")
        t.assertEquals(err.effect, "completed")
    end)
end

return M
