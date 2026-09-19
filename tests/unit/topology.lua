local t = require("luaunit")
local runtime = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local errors = require("libtmux._internal.error")
local available, topology = pcall(require, "libtmux._internal.topology")
local M = {}

local function fixture(kind, version, body)
    t.assertTrue(available, "typed topology operations are missing")
    local driver = drivers.new()
    local rt = runtime.new(driver, { max_active = 1 })
    local generation = assert(identity.generation({
        pid = "1",
        started = "2",
        version = version,
        socket = "/owned/socket",
    }))
    local original =
        { kind = kind, id = kind == "session" and "$2" or "@3", generation = generation }
    local owned = assert(identity.bind(generation, original))
    original.id = "changed"
    local state = { runtime = rt, version = version, calls = {} }
    state.result = { stdout = "native receipt", stderr = "", exit_code = 0, signal = 0 }
    state.bound = {
        generation = function()
            local value, err = identity.evidence(generation)
            return value and generation, err
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
    local function run(action, input, options)
        return topology.run(state, owned, action, input, options)
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

local function reject(request, code)
    local value, err = request:await()
    t.assertNil(value)
    assert(err)
    if code then
        t.assertEquals(err.code, code)
    end
    t.assertEquals(err.effect, "not_sent")
end

function M.test_literal_rename_navigation_renumber_and_kill_use_private_stable_targets()
    fixture("session", "3.7c", function(state, run)
        assert(run("rename", "literal#{pid};λ"):await())
        local options = { activity = true, process = { timeout = 42 } }
        local request = run("navigate_window", "next", options)
        options.activity, options.process.timeout = false, 999
        assert(request:await())
        assert(run("navigate_window", "previous"):await())
        assert(run("navigate_window", "last"):await())
        assert(run("renumber_windows"):await())
        assert(run("kill"):await())
        t.assertEquals(
            state.calls[1].argv,
            { "rename-session", "-t", "$2", "--", "literal##{pid};λ" }
        )
        t.assertEquals(state.calls[2].argv, { "next-window", "-t", "$2", "-a" })
        t.assertEquals(state.calls[2].options.timeout, 42)
        t.assertEquals(state.calls[3].argv, { "previous-window", "-t", "$2" })
        t.assertEquals(state.calls[4].argv, { "last-window", "-t", "$2" })
        t.assertEquals(state.calls[5].argv, { "move-window", "-t", "$2", "-r" })
        t.assertEquals(state.calls[6].argv, { "kill-session", "-t", "$2" })
    end)
    fixture("window", "3.2a", function(state, run)
        assert(run("rename", "window#{pane_id}"):await())
        assert(run("kill"):await())
        t.assertEquals(
            state.calls[1].argv,
            { "rename-window", "-t", "@3", "--", "window##{pane_id}" }
        )
        t.assertEquals(state.calls[2].argv, { "kill-window", "-t", "@3" })
    end)
end

function M.test_resize_and_layout_select_exactly_one_explicit_native_mode()
    fixture("window", "3.7c", function(state, run)
        local options = { width = 80.0, height = 24.0 }
        local pending = run("resize", nil, options)
        options.width = 999
        assert(pending:await())
        assert(run("resize", nil, { direction = "left", amount = 4 }):await())
        assert(run("resize", nil, { direction = "down" }):await())
        assert(run("resize", nil, { largest = true }):await())
        assert(run("resize", nil, { smallest = true }):await())
        assert(run("layout", nil, { named = "tiled" }):await())
        assert(run("layout", nil, { layout = "native-layout-text" }):await())
        assert(run("layout", nil, { next = true }):await())
        assert(run("layout", nil, { previous = true }):await())
        assert(run("layout", nil, { restore = true }):await())
        local expected = {
            { "resize-window", "-t", "@3", "-x", "80", "-y", "24" },
            { "resize-window", "-t", "@3", "-L", "4" },
            { "resize-window", "-t", "@3", "-D", "1" },
            { "resize-window", "-t", "@3", "-A" },
            { "resize-window", "-t", "@3", "-a" },
            { "select-layout", "-t", "@3", "--", "tiled" },
            { "select-layout", "-t", "@3", "--", "native-layout-text" },
            { "select-layout", "-t", "@3", "-n" },
            { "select-layout", "-t", "@3", "-p" },
            { "select-layout", "-t", "@3", "-o" },
        }
        for index, argv in ipairs(expected) do
            t.assertEquals(state.calls[index].argv, argv)
        end
    end)
end

function M.test_invalid_modes_inputs_process_options_and_metatables_precede_native_effects()
    fixture("session", "3.7c", function(state, run)
        for _, name in ipairs({
            "",
            "dot.name",
            "colon:name",
            "line\n",
            "nul\000",
            string.rep("x", 1025),
        }) do
            reject(run("rename", name))
        end
        reject(run("navigate_window", "other"))
        reject(run("navigate_window", "last", { activity = true }))
        reject(run("navigate_window", "last", { activity = false }))
        reject(run("renumber_windows", nil, { all = true }))
        reject(run("resize", nil, { width = 80 }), "invalid_target")
        reject(run("kill", "extra"))
        reject(run("kill", nil, { process = { env = {} } }))
        reject(run("kill", nil, { process = { deadline = 1e20 } }))
        local touched = false
        local mt = {
            __index = function()
                touched = true
                error("must not run")
            end,
        }
        reject(run("rename", setmetatable({}, mt)))
        reject(run("kill", nil, setmetatable({}, mt)))
        reject(run("kill", nil, { process = setmetatable({}, mt) }))
        t.assertFalse(touched)
        t.assertEquals(#state.calls, 0)
    end)
    fixture("window", "3.7c", function(state, run)
        for _, options in ipairs({
            {},
            { width = 0 },
            { width = 10001 },
            { height = 1.5 },
            { amount = 2 },
            { direction = "left", width = 10 },
            { direction = "diagonal" },
            { direction = "up", amount = 0 },
            { largest = true, smallest = true },
            { largest = true, height = 12 },
            { largest = "yes" },
        }) do
            reject(run("resize", nil, options))
        end
        for _, options in ipairs({
            {},
            { named = "t" },
            { layout = "" },
            { layout = "nul\000" },
            { next = true, restore = true },
            { named = "tiled", previous = true },
            { next = 1 },
            { next = false },
            { spread = true },
        }) do
            reject(run("layout", nil, options))
        end
        reject(run("navigate_window", "next"), "invalid_target")
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_layout_capabilities_are_exact_release_gates()
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
        fixture("window", version, function(state, run)
            assert(run("layout", nil, { named = "main-horizontal" }):await())
            local request = run("layout", nil, { named = "main-vertical-mirrored" })
            if tonumber(version:match("^3%.(%d+)")) < 5 then
                reject(request, "unsupported")
                t.assertEquals(#state.calls, 1)
            else
                assert(request:await())
                t.assertEquals(#state.calls, 2)
            end
        end)
    end
    fixture("window", "3.8", function(state, run)
        reject(run("kill"), "unsupported_version")
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_retained_receipts_native_failure_and_post_completion_stale_are_truthful()
    fixture("window", "3.7c", function(state, run, generation)
        local pending = run("rename", "first")
        pending:on_complete(function(value, err)
            t.assertNil(err)
            t.assertTrue(value)
            t.assertTrue(state.runtime:stats().bytes >= #state.result.stdout)
        end)
        assert(pending:await())
        state.failure = errors.new("exit_failed", "native failure after unzoom", {
            effect = "completed",
            partial = state.result,
        })
        local value, err = run("layout", nil, { layout = "bad-native-layout" }):await()
        t.assertNil(value)
        t.assertIs(err, state.failure)
        t.assertEquals(err.effect, "completed")
        state.failure = nil
        state.before = function()
            identity.invalidate(generation, "connection lost")
        end
        value, err = run("kill"):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "stale_generation")
        t.assertEquals(err.effect, "completed")
        t.assertIs(err.partial, state.result)
        t.assertEquals(#state.calls, 3)
    end)
end

function M.test_admission_and_stale_generation_reject_without_dispatch()
    fixture("session", "3.7c", function(state, run, generation)
        state.runtime._limits.max_bytes = 8
        reject(run("rename", string.rep("x", 64)), "queue_full")
        state.runtime._limits.max_bytes = 10000
        local pending = run("kill")
        identity.invalidate(generation)
        reject(pending, "stale_generation")
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_cancellation_never_retries_and_owned_native_retirement_is_joined()
    fixture("window", "3.7c", function(state, run, _, driver)
        local pending = run("rename", "before")
        pending:cancel()
        reject(pending, "cancelled")
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
        pending = run("kill")
        local value, err = pending:await()
        t.assertNil(value)
        t.assertEquals(assert(err).effect, "unknown")
        t.assertFalse(retired)
        t.assertEquals(#state.calls, 1)
    end)
end

return M
