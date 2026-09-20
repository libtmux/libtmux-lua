local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local entities = require("libtmux._internal.entity")
local errors = require("libtmux._internal.error")
local available, client = pcall(require, "libtmux._internal.client")
local M = {}

local function frame(name, tty)
    local function quote(value)
        return value:gsub("([\\;])", "\\%1")
    end
    return "LQ1\r$a;" .. quote(name) .. ";" .. quote(tty) .. ";.\n"
end

local function fixture(body, limits)
    t.assertTrue(available, "typed client operations are missing")
    local driver = drivers.new()
    local rt = runtimes.new(driver, limits or { max_active = 1 })
    local generation = assert(identity.generation({
        pid = "1",
        started = "2",
        version = "3.7c",
        socket = "/owned/socket",
    }))
    local state = { runtime = rt, version = "3.7c", calls = {} }
    state.listing = frame("/dev/pts/7", "/dev/pts/7")
    state.bound = {
        generation = function()
            local value, err = identity.evidence(generation)
            return value and generation, err
        end,
        execute = function(_, argv, options)
            state.calls[#state.calls + 1] = { argv = argv, options = options }
            return rt:_operation(function(_, request)
                if state.before then
                    state.before(argv)
                end
                if state.failure then
                    return nil, state.failure
                end
                local output = argv[1] == "list-clients" and state.listing or ""
                assert(request:_retain(#output))
                return { stdout = output, stderr = "", exit_code = 0, signal = 0 }
            end)
        end,
    }
    local session = assert(entities.from_reference(state, {
        kind = "session",
        id = "$2",
        generation = generation,
    }))
    local function run(kind, selector, destination, options)
        return client.run(state, kind, selector, destination, options, entities.inspect)
    end
    local root = rt:start(function()
        return body(state, run, session, generation)
    end)
    driver:drain()
    local _, err = root:result()
    t.assertNil(err)
    t.assertTrue(root:is_retired())
    t.assertEquals(rt:stats().bytes, 0)
    t.assertEquals(rt:stats().active, 0)
end

local function reject(request, code, effect)
    local value, err = request:await()
    t.assertNil(value)
    t.assertNotNil(err)
    t.assertEquals(err.code, code)
    t.assertEquals(err.effect, effect or "not_sent")
end

function M.test_switch_copies_selector_options_and_private_session_identity()
    fixture(function(state, run, session)
        local selector = { name = "/dev/pts/7", tty = "/dev/pts/7" }
        local options = { process = { timeout = 20 } }
        local pending = run("switch", selector, session, options)
        selector.name, selector.tty, options.process.timeout = "changed", "changed", 99
        session:reference().id = "$999"
        t.assertTrue(pending:await())
        t.assertEquals(
            state.calls[2].argv,
            { "switch-client", "-E", "-c", "/dev/pts/7", "-t", "$2" }
        )
        t.assertEquals(state.calls[2].options.timeout, 20)
        selector = { name = "/dev/pts/7", tty = "/dev/pts/7" }
        t.assertTrue(run("switch", selector, session, { update_environment = true }):await())
        t.assertEquals(state.calls[4].argv, { "switch-client", "-c", "/dev/pts/7", "-t", "$2" })
        t.assertTrue(run("detach", selector):await())
        t.assertEquals(state.calls[6].argv, { "detach-client", "-t", "/dev/pts/7" })
    end)
end

function M.test_missing_mismatched_and_ambiguous_clients_never_dispatch_mutation()
    fixture(function(state, run)
        local selector = { name = "/dev/pts/7", tty = "/dev/pts/7" }
        state.listing = ""
        reject(run("detach", selector), "missing_target")
        state.listing = frame(selector.name, "/dev/pts/8")
        reject(run("detach", selector), "missing_target")
        state.listing = frame(selector.name, selector.tty):rep(2)
        reject(run("detach", selector), "ambiguous_target")
        state.listing = frame(selector.name, selector.tty) .. frame("other", selector.name)
        reject(run("detach", selector), "ambiguous_target")
        for _, call in ipairs(state.calls) do
            t.assertEquals(call.argv[1], "list-clients")
        end
    end)
end

function M.test_exact_names_handle_native_colon_and_abbreviation_rules()
    fixture(function(state, run)
        local selector = { name = "client:;", tty = "" }
        state.listing = frame(selector.name, selector.tty)
        t.assertTrue(run("detach", selector):await())
        t.assertEquals(state.calls[2].argv, { "detach-client", "-t", "client:;" })
        selector.name = "client:"
        state.listing = frame(selector.name, "")
        t.assertTrue(run("detach", selector):await())
        t.assertEquals(state.calls[4].argv, { "detach-client", "-t", "client::" })
        state.listing = frame("pts/7", "") .. frame("/dev/pts/7", "/dev/pts/7")
        reject(run("detach", { name = "pts/7", tty = "" }), "ambiguous_target")
    end)
end

function M.test_invalid_inputs_and_foreign_sessions_fail_before_io()
    fixture(function(state, run, session, generation)
        local selector = { name = "/dev/pts/7", tty = "/dev/pts/7" }
        for _, value in ipairs({
            false,
            {},
            { name = selector.name },
            { name = "", tty = "" },
            { name = "x\000", tty = "" },
            { name = "x", tty = "", extra = true },
            setmetatable({}, {}),
        }) do
            reject(run("detach", value), "invalid_target")
        end
        reject(run("switch", selector, {}), "invalid_target")
        local other = { runtime = state.runtime, bound = state.bound }
        local foreign = assert(
            entities.from_reference(other, { kind = "session", id = "$2", generation = generation })
        )
        reject(run("switch", selector, foreign), "invalid_target")
        reject(run("switch", selector, session, { update_environment = 1 }), "invalid_options")
        reject(run("detach", selector, nil, { update_environment = true }), "invalid_options")
        reject(run("detach", selector, nil, { process = { env = {} } }), "invalid_options")
        reject(
            run("detach", selector, nil, { process = { max_output_bytes = 1048577 } }),
            "invalid_options"
        )
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_close_cancellation_and_generation_loss_prevent_mutation()
    fixture(function(state, run, _, generation)
        local selector = { name = "/dev/pts/7", tty = "/dev/pts/7" }
        local pending = run("detach", selector)
        pending:cancel()
        reject(pending, "cancelled")
        pending = run("detach", selector)
        state.closed = true
        reject(pending, "closed")
        state.closed = false
        t.assertEquals(#state.calls, 0)
        state.before = function()
            identity.invalidate(generation)
        end
        reject(run("detach", selector), "stale_generation")
        t.assertEquals(#state.calls, 1)
    end)
end

function M.test_preflight_and_mutation_errors_keep_distinct_effects()
    fixture(function(state, run)
        local selector = { name = "/dev/pts/7", tty = "/dev/pts/7" }
        state.failure = errors.new("exit_failed", "listing failed", { effect = "completed" })
        reject(run("detach", selector), "exit_failed")
        state.failure = nil
        state.before = function(argv)
            if argv[1] ~= "list-clients" then
                state.failure = errors.new("exit_failed", "client left", { effect = "completed" })
            end
        end
        reject(run("detach", selector), "exit_failed", "completed")
    end)
end

function M.test_interactive_attach_reports_adapter_limit_without_io()
    fixture(function(state, _, session)
        reject(session:attach(), "unsupported_tty")
        t.assertEquals(#state.calls, 0)
    end)
end

function M.test_generation_loss_after_mutation_preserves_completed_receipt()
    fixture(function(state, run, _, generation)
        state.before = function(argv)
            if argv[1] == "detach-client" then
                identity.invalidate(generation)
            end
        end
        local value, err = run("detach", { name = "/dev/pts/7", tty = "/dev/pts/7" }):await()
        t.assertNil(value)
        t.assertEquals(err.code, "stale_generation")
        t.assertEquals(err.effect, "completed")
        t.assertNotNil(err.partial, "completed client command must retain its native receipt")
        t.assertEquals(err.partial.exit_code, 0)
    end)
end

return M
