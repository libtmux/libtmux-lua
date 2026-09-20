local t = require("luaunit")
local identity = require("libtmux._internal.identity")
local available, scope = pcall(require, "libtmux._internal.scope")
local M = {}

local function fixture(kind)
    t.assertTrue(available, "settings scope resolver is missing")
    local generation =
        assert(identity.generation({ pid = "1", started = "2", socket = "s", version = "3.7c" }))
    local state = {
        bound = {
            generation = function()
                local evidence, err = identity.evidence(generation)
                return evidence and generation, err
            end,
        },
    }
    local owned
    if kind then
        owned = assert(identity.bind(generation, {
            generation = generation,
            kind = kind,
            id = ({ session = "$2", window = "@3", pane = "%4" })[kind],
        }))
    end
    return state, owned, generation
end

function M.test_explicit_storage_scope_never_falls_back_to_native_inference()
    for _, row in ipairs({
        { nil, nil, "option", "server", { "-s" } },
        { nil, "global_session", "option", "global_session", { "-g" } },
        { nil, "global_window", "hook", "global_window", { "-g", "-w" } },
        { "session", nil, "option", "session", { "-t", "$2" } },
        { "window", nil, "hook", "window", { "-w", "-t", "@3" } },
        { "pane", nil, "option", "pane", { "-p", "-t", "%4" } },
        { nil, nil, "environment", "global", { "-g" } },
        { "session", nil, "environment", "session", { "-t", "$2" } },
    }) do
        local state, owned = fixture(row[1])
        local result, err = scope.resolve(state, owned, row[2], row[3])
        t.assertNil(err)
        assert(result)
        t.assertEquals(result.scope, row[4])
        t.assertEquals(result.flags, row[5])
    end
    for _, row in ipairs({
        { nil, nil, "hook" },
        { nil, "global_pane", "option" },
        { "session", "global_session", "option" },
        { "window", "pane", "option" },
        { "pane", nil, "environment" },
        { nil, "server", "hook" },
    }) do
        local state, owned = fixture(row[1])
        local result, err = scope.resolve(state, owned, row[2], row[3])
        t.assertNil(result)
        t.assertEquals(assert(err).code, "invalid_scope")
        t.assertEquals(assert(err).effect, "not_sent")
    end
end

function M.test_catalog_scope_check_prevents_silent_scope_widening()
    local state, owned = fixture("pane")
    local resolved = assert(scope.resolve(state, owned, nil, "option"))
    local valid, err = scope.check_option(resolved, { scopes = { "session" } })
    t.assertNil(valid)
    t.assertEquals(assert(err).code, "invalid_scope")
    t.assertTrue(scope.check_option(resolved, { scopes = { "window", "pane" } }))
    state, owned = fixture()
    resolved = assert(scope.resolve(state, owned, "global_window", "option"))
    t.assertTrue(scope.check_option(resolved, { scopes = { "window", "pane" } }))
end

function M.test_reference_validation_rejects_closed_stale_and_foreign_handles()
    local state, owned, generation = fixture("pane")
    local resolved = assert(scope.resolve(state, owned, nil, "option"))
    resolved.target.id = "%999"
    t.assertEquals(assert(scope.resolve(state, owned, nil, "option")).target.id, "%4")
    local other = fixture("pane")
    local value, err = scope.resolve(other, owned, nil, "option")
    t.assertNil(value)
    t.assertEquals(assert(err).code, "stale_generation")
    identity.invalidate(generation, "test")
    value, err = scope.resolve(state, owned, nil, "option")
    t.assertNil(value)
    t.assertEquals(assert(err).code, "stale_generation")
    state.closed = true
    value, err = scope.resolve(state, owned, nil, "option")
    t.assertNil(value)
    t.assertEquals(assert(err).code, "closed")
end

return M
