local test = require("luaunit")
local identity = require("libtmux._internal.identity")
local query = require("libtmux.query")
local available, graph = pcall(require, "libtmux._internal.graph")
local M = {}

local function fixture()
    test.assertTrue(available, "canonical snapshot graph is not implemented")
    local generation = assert(identity.generation({
        pid = "123",
        started = "456",
        socket = "/owned/socket",
        version = "3.7c",
    }))
    ---@type libtmux.Fields.Client
    local client = { name = "client", tty = "", session_name = "first" }
    local rows = {
        sessions = { { id = "$1", name = "first" }, { id = "$2", name = "second" } },
        windows = { { id = "@3", name = "shared" }, { id = "@3", name = "shared" } },
        panes = {
            { id = "%4", window_id = "@3", active = false, title = "" },
            { id = "%4", window_id = "@3", active = false, title = "" },
        },
        window_links = {
            { session_id = "$1", window_id = "@3", index = 0, active = false },
            { session_id = "$2", window_id = "@3", index = 7, active = true },
        },
        clients = { client },
        buffers = { { name = "bytes", size = 3 } },
    }
    return generation, rows
end

function M.test_canonical_entities_and_contextual_links_preserve_order()
    local generation, rows = fixture()
    local snapshot = assert(graph.build(generation, rows, { started = 10, finished = 20 }))
    test.assertEquals(#snapshot.windows, 1)
    test.assertEquals(#snapshot.panes, 1)
    test.assertEquals(#snapshot.raw.windows, 2)
    test.assertEquals(#snapshot.raw.panes, 2)
    test.assertEquals(#snapshot.window_links, 2)
    test.assertEquals(snapshot.window_links[2].index, 7)
    test.assertNil(snapshot.windows[1].index)
    test.assertNil(snapshot.windows[1].active)
    test.assertIs(snapshot.window_links[1].window, snapshot.windows[1])
    test.assertIs(snapshot.window_links[2].window, snapshot.windows[1])
    test.assertIs(snapshot.sessions[1].window_links[1], snapshot.window_links[1])
    test.assertIs(snapshot.panes[1].window, snapshot.windows[1])
    test.assertIs(snapshot.clients[1].session, snapshot.sessions[1])
    test.assertTrue(snapshot.complete)
    test.assertEquals(snapshot.acquisition, { started = 10, finished = 20 })
    local matched = snapshot.sessions:where({
        window_links = { some = { window = { is = { panes = { some = { active = false } } } } } },
    })
    test.assertEquals(#matched, 2)
    test.assertEquals(#snapshot.panes:where({ window = { is = { name = "shared" } } }), 1)
    test.assertEquals(#snapshot.raw.panes:where({ active = false }), 2)
end

function M.test_mutable_records_cannot_redirect_private_identity_or_old_snapshot()
    local generation, rows = fixture()
    local snapshot = assert(graph.build(generation, rows, { started = 1, finished = 2 }))
    local pane = snapshot.panes[1]
    rows.panes[1].title = "input changed"
    pane.ref.id = "%9"
    pane.id = "%8"
    local handle = assert(graph.handle(snapshot, pane))
    test.assertEquals(identity.inspect(generation, handle).id, "%4")
    test.assertIs(graph.lookup(snapshot, "pane", "%4"), pane)
    test.assertNil(graph.lookup(snapshot, "pane", "%8"))
    test.assertEquals(pane.title, "")
    local newer = assert(graph.build(generation, rows, { started = 3, finished = 4 }))
    test.assertEquals(newer.panes[1].title, "input changed")
    test.assertEquals(pane.title, "")
    identity.invalidate(generation)
    local value, err = graph.handle(snapshot, pane)
    test.assertNil(value)
    test.assertEquals(assert(err).code, "stale_generation")
end

function M.test_races_remain_visible_and_strict_assembly_rejects_them()
    local generation, rows = fixture()
    rows.windows[2].name = "changed between listings"
    rows.window_links[2].session_id = "$99"
    rows.clients[1].session_name = query.NULL
    local snapshot = assert(graph.build(generation, rows, { started = 1, finished = 2 }))
    test.assertFalse(snapshot.complete)
    test.assertEquals(#snapshot.races, 2)
    test.assertEquals(snapshot.races[1].code, "conflicting_entity")
    test.assertEquals(snapshot.races[2].code, "missing_relation")
    test.assertNil(snapshot.window_links[2].session)
    test.assertIs(snapshot.clients[1].session, query.NULL)
    local strict, err = graph.build(generation, rows, { started = 1, finished = 2, strict = true })
    test.assertNil(strict)
    test.assertEquals(assert(err).code, "inconsistent_snapshot")
    test.assertEquals(#assert(err).partial.races, 2)
end

function M.test_snapshot_validation_is_bounded_and_has_no_hidden_io()
    local generation, rows = fixture()
    rows.panes = { [2] = { id = "%4", window_id = "@3" } }
    local value, err = graph.build(generation, rows, { started = 1, finished = 2 })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "invalid_snapshot")
    generation, rows = fixture()
    value, err = graph.build(generation, rows, { started = 1, finished = 2, max_rows = 2 })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "snapshot_limit")
    rows.windows[1].index = 8
    value, err = graph.build(generation, rows, { started = 1, finished = 2 })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "invalid_snapshot")
    local called = false
    rows.windows[1].index = nil
    setmetatable(rows.sessions[1], {
        __index = function()
            called = true
        end,
    })
    value, err = graph.build(generation, rows, { started = 1, finished = 2 })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "invalid_snapshot")
    test.assertFalse(called)
end

function M.test_ambiguous_names_and_conflicting_link_observations_cannot_pass_strict()
    local generation, rows = fixture()
    rows.sessions[1].name, rows.sessions[2].name = "same", "same"
    rows.clients[1].session_name = "same"
    local snapshot = assert(graph.build(generation, rows, { started = 1, finished = 2 }))
    test.assertFalse(snapshot.complete)
    test.assertNil(snapshot.clients[1].session)
    local value, err = graph.build(generation, rows, { started = 1, finished = 2, strict = true })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "inconsistent_snapshot")
    generation, rows = fixture()
    rows.window_links[2] = { session_id = "$1", window_id = "@3", index = 0, active = true }
    snapshot = assert(graph.build(generation, rows, { started = 1, finished = 2 }))
    test.assertEquals(#snapshot.window_links, 2)
    test.assertFalse(snapshot.complete)
    test.assertEquals(snapshot.races[1].code, "conflicting_entity")
    value, err = graph.build(generation, rows, { started = 1, finished = 2, strict = true })
    test.assertNil(value)
    test.assertEquals(assert(err).code, "inconsistent_snapshot")
end

return M
