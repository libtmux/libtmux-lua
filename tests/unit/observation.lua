local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local entities = require("libtmux._internal.entity")
local control = require("libtmux._internal.control")
local available, observation = pcall(require, "libtmux._internal.observation")
local M = {}

local function fixture(body, limits)
    t.assertTrue(available, "shared observation API is missing")
    local driver = drivers.new()
    local rt = runtimes.new(driver, limits)
    local generation = assert(identity.generation({
        pid = "1",
        started = "2",
        version = "3.7c",
        socket = "/owned/socket",
    }))
    local f =
        { runtime = rt, driver = driver, opens = 0, closes = 0, connections = {}, version = "3.7c" }
    f.bound = {
        generation = function()
            return generation
        end,
    }
    f.session =
        assert(entities.from_reference(f, { generation = generation, kind = "session", id = "$0" }))
    f.pane =
        assert(entities.from_reference(f, { generation = generation, kind = "pane", id = "%0" }))
    local original = control.open
    ---@diagnostic disable-next-line: duplicate-set-field
    control.open = function(runtime, _, options)
        f.opens = f.opens + 1
        local connection = { token = {}, options = options, watches = {} }
        f.connections[#f.connections + 1] = connection
        local lease = assert(runtime:_resource(function(done)
            connection.closed = true
            f.closes = f.closes + 1
            if f.hold_close then
                f.finish_close = done
            else
                done()
            end
        end))
        function connection.close()
            return lease:close()
        end
        function connection:_status()
            return not self.closed
        end
        function connection:coverage()
            return { generation = self.token, session_id = "$0", panes = { "%0" }, ready = true }
        end
        local function watch()
            local w = { close_count = 0 }
            connection.watches[#connection.watches + 1] = w
            function w:next()
                return runtime:_logical_request({
                    start = function(settle, retire)
                        if self.closed then
                            settle(nil)
                            retire()
                        else
                            self.settle, self.retire = settle, retire
                            return function()
                                self.settle = nil
                                retire()
                            end
                        end
                    end,
                })
            end
            function w:close()
                if not self.closed then
                    self.closed, self.close_count = true, self.close_count + 1
                    if self.settle then
                        self.settle(nil)
                        self.retire()
                        self.settle = nil
                    end
                end
                if not self.close_request then
                    if f.hold_watch_close then
                        self.close_request = runtime:_logical_request({
                            start = function(settle, retire)
                                f.finish_watch_close = function()
                                    settle(true)
                                    retire()
                                end
                                return function()
                                    retire()
                                end
                            end,
                        })
                    else
                        self.close_request = runtime:_operation(function()
                            return true
                        end)
                    end
                end
                return self.close_request
            end
            local opening = runtime:_operation(function()
                return w
            end)
            opening:_on_retire(function()
                if f.on_watch_retired then
                    f.on_watch_retired()
                end
            end)
            return opening
        end
        connection.watch_pane, connection.watch_notifications, connection.subscribe_format =
            watch, watch, watch
        local request = runtime:_logical_request({
            start = function(settle, retire)
                f.ready = function()
                    settle(connection)
                    retire()
                end
                if not f.hold_open then
                    f.ready()
                end
                return function()
                    retire()
                end
            end,
        })
        return request,
            function()
                t.assertTrue(request:is_retired())
                return lease:close()
            end
    end
    f.root = rt:start(function()
        return body(f)
    end)
    local ok, err = pcall(driver.drain, driver)
    control.open = original
    if not ok then
        error(err)
    end
    return f
end

local function finished(f)
    local _, err = f.root:result()
    t.assertNil(err)
    t.assertTrue(f.root:is_retired())
    t.assertEquals(f.runtime:stats().resources, 0)
    t.assertEquals(f.runtime:stats().resource_bytes, 0)
end

function M.test_shared_startup_survives_one_borrower_cancellation()
    local f = fixture(function(s)
        s.hold_open = true
        local first = observation.open(s, s.session)
        local second = observation.open(s, s.session)
        s.driver.defer(function()
            first:cancel()
            s.driver.defer(function()
                s.ready()
            end)
        end)
        local handle = assert(second:await())
        t.assertEquals(s.opens, 1)
        t.assertEquals(s.closes, 0)
        t.assertTrue(handle:close():await())
        t.assertEquals(s.closes, 1)
    end)
    finished(f)
end

function M.test_final_close_waits_native_retirement_and_blocks_overlap()
    local f = fixture(function(s)
        local a = assert(observation.open(s, s.session):await())
        local b = assert(observation.open(s, s.session):await())
        t.assertTrue(a:close():await())
        t.assertEquals(s.closes, 0)
        s.hold_close = true
        local closing = b:close()
        local _, err = observation.open(s, s.session):await()
        t.assertEquals(err.code, "closing")
        s.driver.defer(function()
            t.assertFalse(closing:is_settled())
            s.hold_close = false
            s.finish_close()
        end)
        t.assertTrue(closing:await())
        local c = assert(observation.open(s, s.session):await())
        t.assertFalse(rawequal(b:coverage(), c:coverage()))
        t.assertEquals(s.opens, 2)
    end)
    finished(f)
end

function M.test_connection_limits_and_private_entity_identity_are_validated()
    local f = fixture(function(s)
        local options = { max_bytes = 1024 }
        local pending = observation.open(s, s.session, options)
        options.max_bytes = 2048
        local a = assert(pending:await())
        local _, err = observation.open(s, s.session, options):await()
        t.assertEquals(err.code, "option_conflict")
        _, err = observation.open(s, s.pane):await()
        t.assertEquals(err.code, "invalid_target")
        _, err = observation
            .open(s, {
                reference = function()
                    error("caller code ran")
                end,
            })
            :await()
        t.assertEquals(err.code, "invalid_target")
        s.session.reference = function()
            error("overridden method ran")
        end
        local b = assert(observation.open(s, s.session, { max_bytes = 1024 }):await())
        t.assertEquals(s.opens, 1)
        t.assertEquals(s.connections[1].options.max_bytes, 1024)
        t.assertTrue(a:close():await())
        t.assertTrue(b:close():await())
    end)
    finished(f)
end

function M.test_closing_one_observer_closes_only_its_watches()
    local f = fixture(function(s)
        local a = assert(observation.open(s, s.session):await())
        local b = assert(observation.open(s, s.session):await())
        local aw = assert(a:watch_pane(s.pane):await())
        local bw = assert(b:watch_pane(s.pane):await())
        local ar, br = aw:next(), bw:next()
        t.assertTrue(a:close():await())
        t.assertTrue(ar:is_settled())
        t.assertFalse(br:is_settled())
        t.assertEquals(s.closes, 0)
        t.assertTrue(bw:close():await())
        t.assertTrue(br:is_settled())
        t.assertEquals(s.connections[1].watches[1].close_count, 1)
        t.assertEquals(s.connections[1].watches[2].close_count, 1)
        t.assertTrue(b:close():await())
    end)
    finished(f)
end

function M.test_canceled_final_startup_keeps_entry_until_native_cleanup()
    local f = fixture(function(s)
        s.hold_open, s.hold_close = true, true
        local pending = observation.open(s, s.session)
        s.driver.defer(function()
            s.driver.defer(function()
                pending:cancel()
            end)
        end)
        local _, err = pending:await()
        t.assertEquals(err.code, "cancelled")
        _, err = observation.open(s, s.session):await()
        t.assertEquals(err.code, "closing")
        s.driver.defer(function()
            t.assertEquals(s.opens, 1)
            t.assertEquals(s.closes, 1)
            s.finish_close()
        end)
    end)
    finished(f)
end

function M.test_server_close_before_startup_delivery_cannot_publish_observer()
    local f = fixture(function(s)
        s.hold_open = true
        local pending = observation.open(s, s.session)
        s.driver.defer(function()
            s.driver.defer(function()
                s.ready()
                s.closed = true
            end)
        end)
        local observer, err = pending:await()
        t.assertNil(observer, "closed server published an observation")
        t.assertEquals(assert(err).code, "closed")
    end)
    finished(f)
    t.assertEquals(f.closes, 1)
end

function M.test_observer_close_joins_canceled_watch_unsubscribe_after_lost_delivery()
    local f = fixture(function(s)
        local a = assert(observation.open(s, s.session):await())
        local b = assert(observation.open(s, s.session):await())
        s.hold_watch_close = true
        local pending = a:subscribe_format(s.pane, { "title" })
        s.on_watch_retired = function()
            pending:cancel()
        end
        local value, err = pending:await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "cancelled")
        local closing = a:close()
        s.driver.defer(function()
            s.driver.defer(function()
                s.closed_before_unsubscribe = closing:is_retired()
                s.finish_watch_close()
            end)
        end)
        t.assertTrue(closing:await())
        t.assertEquals(s.closes, 0)
        t.assertTrue(b:close():await())
    end)
    finished(f)
    t.assertFalse(f.closed_before_unsubscribe, "observer closed before discarded watch cleanup")
end

return M
