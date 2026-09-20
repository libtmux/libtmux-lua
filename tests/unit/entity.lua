local t = require("luaunit")
local identity = require("libtmux._internal.identity")
local graph = require("libtmux._internal.graph")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local available, entities = pcall(require, "libtmux._internal.entity")
local M = {}

local function fixture(body)
    t.assertTrue(available, "entity handles are missing")
    local generation = assert(identity.generation({
        pid = "1",
        started = "2",
        socket = "/owned/socket",
        version = "3.7c",
    }))
    local rows = {
        sessions = { { id = "$0", name = "one" } },
        windows = { { id = "@0" } },
        panes = { { id = "%0", window_id = "@0", title = "old" } },
        window_links = { { session_id = "$0", window_id = "@0", index = 0 } },
        clients = { { name = "client", tty = "/dev/pts/1", session_name = "one" } },
        buffers = { { name = "buffer" } },
    }
    local driver = drivers.new()
    local rt = runtimes.new(driver)
    local state = { runtime = rt, calls = 0 }
    state.bound = {
        generation = function()
            local value, err = identity.evidence(generation)
            if not value then
                return nil, err
            end
            return generation
        end,
    }
    state.capture = function()
        state.calls = state.calls + 1
        return rt:_operation(function(_, operation)
            if state.capture_bytes then
                assert(operation:_retain(state.capture_bytes))
            end
            return graph.build(generation, rows, { started = 0, finished = 1 })
        end)
    end
    local first = assert(graph.build(generation, rows, { started = 0, finished = 1 }))
    local root = rt:start(function()
        return body(state, first, rows, generation)
    end)
    driver:drain()
    local _, err = root:result()
    t.assertNil(err)
    t.assertTrue(root:is_retired())
end

function M.test_handle_uses_private_identity_and_explicit_refresh()
    fixture(function(state, snapshot, rows)
        local pane = snapshot.panes[1]
        pane.id, pane.ref.id = "%9", "%8"
        local handle = assert(entities.from_snapshot(state, snapshot, pane))
        t.assertEquals(state.calls, 0)
        t.assertEquals(handle:reference().id, "%0")
        local exposed = handle:reference()
        exposed.id = "%7"
        rows.panes[1].title = "new"
        local current = assert(handle:snapshot():await())
        t.assertEquals(current.id, "%0")
        t.assertEquals(current.title, "new")
        t.assertEquals(pane.title, "old")
        t.assertEquals(state.calls, 1)
    end)
end

function M.test_contextual_handles_require_same_link_tty_and_name()
    fixture(function(state, snapshot, rows)
        local link = assert(entities.from_snapshot(state, snapshot, snapshot.window_links[1]))
        local client = assert(entities.from_snapshot(state, snapshot, snapshot.clients[1]))
        local buffer = assert(entities.from_snapshot(state, snapshot, snapshot.buffers[1]))
        rows.window_links[1].index = 9
        rows.clients[1].tty = "/dev/pts/2"
        rows.buffers[1].name = "replacement"
        for _, handle in ipairs({ link, client, buffer }) do
            local value, err = handle:snapshot():await()
            t.assertNil(value)
            t.assertEquals(err.code, "target_missing")
        end
    end)
end

function M.test_stale_generation_and_foreign_records_fail_without_capture()
    fixture(function(state, snapshot, _, generation)
        local pane = assert(entities.from_snapshot(state, snapshot, snapshot.panes[1]))
        local value, err = entities.from_snapshot(state, snapshot, { id = "%0" })
        t.assertNil(value)
        assert(err)
        t.assertEquals(err.code, "invalid_reference")
        identity.invalidate(generation)
        value, err = pane:snapshot():await()
        t.assertNil(value)
        assert(err)
        t.assertEquals(err.code, "stale_generation")
        t.assertEquals(state.calls, 0)
    end)
end

function M.test_returned_record_keeps_capture_budget_until_caller_delivery()
    fixture(function(state, snapshot)
        state.capture_bytes = 200
        local handle = assert(entities.from_snapshot(state, snapshot, snapshot.panes[1]))
        local pending = handle:snapshot()
        pending:on_complete(function(value, err)
            t.assertNil(err)
            t.assertNotNil(value)
            t.assertTrue(state.runtime:stats().bytes >= 200)
        end)
        t.assertNotNil(pending:await())
    end)
end

function M.test_returned_entity_state_survives_live_gc_and_releases_root_cycle()
    local watched = setmetatable({}, { __mode = "v" })
    fixture(function(state, snapshot)
        local handle = assert(entities.from_snapshot(state, snapshot, snapshot.panes[1]))
        watched[1] = handle
        collectgarbage("collect")
        t.assertEquals(handle:reference().id, "%0")
        t.assertNotNil(handle:snapshot():await())
        return handle
    end)
    collectgarbage("collect")
    collectgarbage("collect")
    t.assertNil(watched[1])
end

return M
