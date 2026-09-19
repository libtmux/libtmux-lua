local test = require("luaunit")
local available, identity = pcall(require, "libtmux._internal.identity")
local M = {}

function M.test_handles_copy_references_and_generation_evidence()
    test.assertTrue(available, "generation-bound identity is not implemented")
    local evidence = { pid = "123", started = "456", socket = "/owned/socket", version = "3.7c" }
    local generation = assert(identity.generation(evidence))
    evidence.pid = "999"
    test.assertEquals(identity.evidence(generation).pid, "123")
    local reference = { generation = generation, kind = "pane", id = "%3" }
    local handle = assert(identity.bind(generation, reference))
    reference.id = "%7"
    handle.id = "%8"
    local copied = assert(identity.inspect(generation, handle))
    test.assertEquals(copied.id, "%3")
    copied.id = "%9"
    test.assertEquals(identity.inspect(generation, handle).id, "%3")
end

function M.test_stale_uncertain_and_foreign_generations_never_rebind_ids()
    test.assertTrue(available, "generation-bound identity is not implemented")
    local evidence = { pid = "123", started = "456", socket = "/owned/socket", version = "3.7c" }
    local first = assert(identity.generation(evidence))
    local second = assert(identity.generation(evidence))
    test.assertFalse(first == second)
    local handle = assert(identity.bind(first, { generation = first, kind = "session", id = "$0" }))
    local value, err = identity.inspect(second, handle)
    test.assertNil(value)
    test.assertEquals(assert(err).code, "stale_generation")
    test.assertTrue(identity.invalidate(first, "connection continuity lost"))
    test.assertFalse(identity.invalidate(first, "another reason"))
    value, err = identity.inspect(first, handle)
    test.assertNil(value)
    test.assertEquals(assert(err).code, "stale_generation")
    test.assertEquals(assert(err).reason, "connection continuity lost")
    value, err = identity.bind(second, { generation = first, kind = "session", id = "$0" })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "stale_generation")
end

function M.test_link_client_and_buffer_identity_preserves_context()
    test.assertTrue(available, "generation-bound identity is not implemented")
    local generation =
        assert(identity.generation({ pid = "1", started = "2", socket = "s", version = "3.2a" }))
    for _, record in ipairs({
        { kind = "server" },
        { kind = "window", id = "@4" },
        { kind = "window_link", session_id = "$1", window_id = "@4", index = 0 },
        { kind = "client", name = "/dev/pts/4", tty = "/dev/pts/4" },
        { kind = "client", name = "client-control", tty = "" },
        { kind = "buffer", name = "literal;\nname" },
    }) do
        record.generation = generation
        local handle, err = identity.bind(generation, record)
        test.assertNil(err)
        test.assertEquals(identity.inspect(generation, handle), record)
    end
    for _, record in ipairs({
        { kind = "session", id = "%1" },
        { kind = "pane", id = "%1", target = "%2" },
        { kind = "window_link", session_id = "$1", window_id = "@4", index = -1 },
        { kind = "window_link", session_id = "$1", index = 0 },
        { kind = "client", name = "x" },
        { kind = "buffer", name = "x\000y" },
        { kind = "buffer", name = "" },
    }) do
        record.generation = generation
        local handle, err = identity.bind(generation, record)
        test.assertNil(handle)
        test.assertEquals(assert(err).code, "invalid_reference")
    end
    local called = false
    local value, err = identity.bind(
        generation,
        setmetatable({}, {
            __index = function()
                called = true
            end,
        })
    )
    test.assertNil(value)
    test.assertEquals(assert(err).code, "invalid_reference")
    test.assertFalse(called)
end

function M.test_generation_equality_never_runs_public_metamethods()
    local evidence = { pid = "1", started = "2", socket = "/owned/socket", version = "3.7c" }
    local first = assert(identity.generation(evidence))
    local second = assert(identity.generation(evidence))
    local handle = assert(identity.bind(first, { generation = first, kind = "pane", id = "%0" }))
    local calls = 0
    local equality = {
        __eq = function()
            calls = calls + 1
            return true
        end,
    }
    setmetatable(first, equality)
    setmetatable(second, equality)
    local value, err = identity.inspect(second, handle)
    test.assertNil(value)
    test.assertEquals(assert(err).code, "stale_generation")
    value, err = identity.bind(second, { generation = first, kind = "pane", id = "%0" })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "stale_generation")
    test.assertEquals(identity.inspect(first, handle).id, "%0")
    test.assertEquals(calls, 0)
end

return M
