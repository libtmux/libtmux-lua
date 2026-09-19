local t = require("luaunit")
local runtimes = require("libtmux._internal.runtime")
local drivers = require("tests.support.runtime_driver")
local identity = require("libtmux._internal.identity")
local available, endpoints = pcall(require, "libtmux._internal.endpoint")
local M = {}

local function fixture()
    t.assertTrue(available, "pinned endpoint is not implemented")
    local driver = drivers.new()
    local uv = { files = {}, calls = {}, spawned = {} }
    local socket = { type = "socket", dev = 1, ino = 10 }
    uv.files["/owned/tmux.sock"] = socket
    local function later(name, fn)
        uv.calls[#uv.calls + 1] = name
        driver.defer(fn)
        return true
    end
    function uv.fs_lstat(path, callback)
        return later("lstat", function()
            if uv.files[path] then
                callback(nil, uv.files[path])
            else
                callback("ENOENT")
            end
        end)
    end
    function uv.fs_mkdtemp(_, callback)
        uv.mkdir_callback = function()
            uv.directory = "/owned/libtmux-lua-pin-test"
            uv.files[uv.directory] = { type = "directory", mode = 448 }
            callback(nil, uv.directory)
        end
        if uv.hold_mkdir then
            return true
        end
        return later("mkdtemp", uv.mkdir_callback)
    end
    function uv.fs_link(from, to, callback)
        return later("link", function()
            uv.files[to] = uv.files[from]
            uv.alias = to
            callback(nil, true)
        end)
    end
    function uv.fs_unlink(path, callback)
        return later("unlink", function()
            uv.files[path] = nil
            callback(nil, true)
        end)
    end
    function uv.fs_rmdir(path, callback)
        return later("rmdir", function()
            uv.files[path] = nil
            callback(nil, true)
        end)
    end
    function uv.new_pipe()
        local pipe = {}
        function pipe:read_start(fn)
            self.read = fn
            return 0
        end
        function pipe.close(_, fn)
            driver.defer(fn)
        end
        return pipe
    end
    function uv.spawn(program, spec, on_exit)
        uv.spawned[#uv.spawned + 1] = { program = program, args = spec.args }
        local metadata = spec.args[#spec.args]:find("#{q:pid}", 1, true)
        local function finish()
            if not metadata or not uv.dead_listener then
                spec.stdio[2].read(
                    nil,
                    metadata and "LQ1\r$a;123;100;3.7c;/owned/tmux.sock;.\n" or "done\n"
                )
            end
            if metadata and uv.evidence_stderr then
                spec.stdio[3].read(nil, uv.evidence_stderr)
            end
            spec.stdio[2].read(nil, nil)
            spec.stdio[3].read(nil, nil)
            on_exit(metadata and uv.dead_listener and 1 or not metadata and uv.exit_code or 0, 0)
        end
        local child = uv.new_pipe()
        function child.kill()
            driver.defer(finish)
            return 0
        end
        if uv.hold_child and not metadata then
            uv.finish_child = finish
        else
            driver.defer(finish)
        end
        return child, 456
    end
    driver.uv = uv
    local runtime = runtimes.new(driver)
    local f = { runtime = runtime, driver = driver, uv = uv }
    function f:start(fn)
        self.root = runtime:start(fn)
        driver:drain()
        if self.root:is_settled() then
            local _, err = self.root:result()
            t.assertNil(err)
        end
    end
    return f
end

function M.test_rejects_untyped_or_relative_options_before_filesystem_effects()
    local f = fixture()
    local touched = false
    local function touch()
        touched = true
        error("metamethod must not run")
    end
    f:start(function(rt)
        for _, options in ipairs({
            false,
            { binary = "tmux", socket = "/owned/tmux.sock" },
            { binary = "/tmux", socket = "relative" },
            { binary = "/tmux", socket = "/owned/tmux.sock", config = false },
            setmetatable({}, { __index = touch, __pairs = touch }),
        }) do
            local value, err = endpoints.bind(rt, options):await()
            t.assertNil(value)
            assert(err)
            t.assertEquals(err.code, "invalid_endpoint")
            t.assertEquals(err.effect, "not_sent")
        end
    end)
    t.assertFalse(touched)
    t.assertEquals(f.uv.calls, {})
    t.assertTrue(f.root:is_retired())
end

function M.test_copies_binding_and_invalidates_replaced_path_without_dispatch()
    local f = fixture()
    local options = { binary = "/actual/tmux", socket = "/owned/tmux.sock", config = "/dev/null" }
    f:start(function(rt)
        local bound, err = endpoints.bind(rt, options):await()
        t.assertNil(err)
        assert(bound)
        options.binary, options.socket = "/wrong/tmux", "/wrong/socket"
        local evidence = assert(bound:evidence())
        t.assertEquals(evidence.pid, "123")
        t.assertEquals(evidence.started, "100")
        evidence.pid = "other"
        t.assertEquals(bound:evidence().pid, "123")
        local generation = assert(bound:generation())
        local result = bound:execute({ "display-message", "-p", "done" }):await()
        t.assertEquals(result.stdout, "done\n")
        t.assertEquals(f.uv.spawned[3].program, "/actual/tmux")
        t.assertEquals(f.uv.spawned[3].args[2], f.uv.alias)
        t.assertNotNil(table.concat(f.uv.spawned[3].args, " "):find(" -N ", 1, true))
        f.uv.files["/owned/tmux.sock"] = { type = "socket", dev = 1, ino = 20 }
        result, err = bound:execute({ "kill-session", "-t", "$0" }):await()
        t.assertNil(result)
        assert(err)
        t.assertEquals(err.code, "stale_generation")
        t.assertEquals(err.effect, "not_sent")
        t.assertEquals(#f.uv.spawned, 3)
        t.assertNil(identity.evidence(generation))
        t.assertTrue(bound:close() == bound:close())
        bound:close():await()
    end)
    t.assertTrue(f.root:is_retired())
    t.assertNil(f.uv.files[f.uv.alias])
    t.assertNil(f.uv.files[f.uv.directory])
    t.assertNotNil(f.uv.files["/owned/tmux.sock"])
end

function M.test_cancelled_bind_removes_directory_allocated_after_cancellation()
    local f = fixture()
    f.uv.hold_mkdir = true
    f:start(function(rt)
        f.binding = endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" })
        f.binding:await()
    end)
    t.assertNotNil(f.uv.mkdir_callback)
    f.binding:cancel()
    f.driver:drain()
    t.assertFalse(f.root:is_retired())
    f.uv.mkdir_callback()
    f.driver:drain()
    local _, err = f.binding:result()
    assert(err)
    t.assertEquals(err.code, "cancelled")
    t.assertTrue(f.root:is_retired())
    t.assertNil(f.uv.files[f.uv.directory])
    t.assertEquals(#f.uv.spawned, 0)
end

function M.test_imprecise_native_inode_is_rejected_before_pin_allocation()
    local f = fixture()
    f.uv.files["/owned/tmux.sock"].ino = 9007199254740992
    f:start(function(rt)
        local bound, err =
            endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
        t.assertNil(bound)
        assert(err)
        t.assertEquals(err.code, "uncertain_generation")
    end)
    t.assertEquals(f.uv.calls, { "lstat" })
end

function M.test_close_waits_for_actual_accepted_process_retirement()
    local f = fixture()
    f:start(function(rt)
        f.bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        f.uv.hold_child = true
        f.pending = f.bound:execute({ "display-message", "-p", "held" })
        f.pending:await()
    end)
    t.assertNotNil(f.uv.finish_child)
    local closed = f.bound:close()
    f.driver:drain()
    t.assertFalse(closed:is_retired())
    t.assertNotNil(f.uv.files[f.uv.alias])
    t.assertNil(f.bound:generation())
    f.uv.finish_child()
    f.driver:drain()
    t.assertTrue(closed:is_retired())
    t.assertTrue(f.root:is_retired())
    t.assertNil(f.uv.files[f.uv.alias])
end

function M.test_endpoint_close_owns_persistent_client_until_native_cleanup()
    local f = fixture()
    local finish, client_lease
    f:start(function(rt)
        f.bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        t.assertEquals(type(f.bound._client), "function", "persistent endpoint lease is missing")
        local marker = f.bound
            :_client(function(_, endpoint, lease)
                t.assertEquals(endpoint.socket, f.uv.alias)
                t.assertTrue(endpoint.no_start)
                client_lease = lease
                return "attached"
            end, function(done)
                finish = done
            end)
            :await()
        t.assertEquals(marker, "attached")
        f.closed = f.bound:close()
        f.closed:await()
    end)
    t.assertEquals(type(finish), "function")
    t.assertFalse(f.closed:is_settled())
    t.assertNotNil(f.uv.files[f.uv.alias])
    finish()
    f.driver:drain()
    t.assertTrue(f.closed:is_retired())
    t.assertTrue(client_lease:close():is_retired())
    t.assertTrue(f.root:is_retired())
    t.assertNil(f.uv.files[f.uv.alias])
end

function M.test_cancelled_persistent_open_closes_its_lease_before_root_return()
    local f = fixture()
    local opened, closed = false, false
    f:start(function(rt)
        f.bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        t.assertEquals(type(f.bound._client), "function", "persistent endpoint lease is missing")
        f.opening = f.bound:_client(function()
            opened = true
            rt:_request({
                start = function(_, retire)
                    return function()
                        retire()
                    end
                end,
            }):await()
        end, function(done)
            closed = true
            done()
        end)
        f.opening:await()
    end)
    t.assertTrue(opened)
    f.opening:cancel()
    f.driver:drain()
    t.assertTrue(closed)
    t.assertTrue(f.root:is_retired())
    t.assertNil(f.uv.files[f.uv.alias])
end

function M.test_generation_invalidation_closes_persistent_clients_without_rebinding()
    local f = fixture()
    local closed = false
    f:start(function(rt)
        local bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        assert(bound
            :_client(function()
                return true
            end, function(done)
                closed = true
                done()
            end)
            :await())
        f.uv.files["/owned/tmux.sock"] = { type = "socket", dev = 1, ino = 99 }
        local value, err = bound:execute({ "display-message", "-p", "unused" }):await()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "stale_generation")
        -- The close callback must run while this root still owns a live endpoint.
        rt:_request({
            start = function(settle, retire)
                settle(true)
                retire()
            end,
        }):await()
        t.assertTrue(closed)
    end)
    t.assertTrue(f.root:is_retired())
end

function M.test_dead_listener_invalidates_generation_before_mutation_dispatch()
    local f = fixture()
    f:start(function(rt)
        local bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        f.uv.dead_listener = true
        local value, err = bound:execute({ "new-session", "-d" }):await()
        t.assertNil(value)
        assert(err)
        t.assertEquals(err.code, "stale_generation")
        t.assertEquals(err.effect, "not_sent")
        t.assertNil(bound:generation())
        t.assertEquals(#f.uv.spawned, 2)
        t.assertNotNil(f.uv.spawned[2].args[#f.uv.spawned[2].args]:find("#{q:pid}", 1, true))
    end)
    t.assertNil(f.uv.files[f.uv.alias])
end

function M.test_queued_endpoint_input_is_charged_before_preflight()
    local f = fixture()
    f:start(function(rt)
        local bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        rt._limits.max_bytes = 8
        local before = #f.uv.calls
        local request = bound:group({ { "display-message", "-p", string.rep("x", 32) } })
        local value, err = request:result()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "queue_full")
        t.assertEquals(assert(err).effect, "not_sent")
        t.assertTrue(request:is_retired())
        t.assertEquals(#f.uv.calls, before)
        t.assertEquals(rt:stats().bytes, 0)
    end)
end

function M.test_result_callbacks_keep_endpoint_output_bytes_reserved()
    for _, mode in ipairs({ "success", "raw_failed", "typed_failed" }) do
        local f = fixture()
        local delivered = false
        f:start(function(rt)
            local bound = assert(
                endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
            )
            f.uv.exit_code = mode == "success" and 0 or 1
            local request = mode == "typed_failed" and bound:execute({ "display-message" })
                or bound:group({ { "display-message" } })
            local initial = request._cost
            request:on_complete(function(value, err)
                local result = value or err.partial
                t.assertEquals(result.stdout, "done\n")
                t.assertEquals(rt:stats().bytes, initial + #result.stdout)
                delivered = true
            end)
        end)
        t.assertTrue(delivered)
        t.assertTrue(f.root:is_retired())
        t.assertEquals(f.runtime:stats().bytes, 0)
    end
end

function M.test_preflight_error_payload_stays_reserved_through_outer_callback()
    local f = fixture()
    local delivered = false
    f:start(function(rt)
        local bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        f.uv.dead_listener, f.uv.evidence_stderr = true, "failed"
        local request = bound:group({ { "display-message" } })
        local initial = request._cost
        request:on_complete(function(value, err)
            t.assertNil(value)
            t.assertEquals(err.cause.cause.partial.stderr, "failed")
            t.assertEquals(rt:stats().bytes, initial + #"failed")
            delivered = true
        end)
    end)
    t.assertTrue(delivered)
    t.assertEquals(f.runtime:stats().bytes, 0)
end

function M.test_returned_endpoint_preserves_state_without_rooting_its_result_cycle()
    local watched = setmetatable({}, { __mode = "k" })
    local function completed_binding()
        local f = fixture()
        f:start(function(rt)
            return assert(
                endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
            )
        end)
        local bound = assert(f.root:result())
        watched[bound] = true
        collectgarbage("collect")
        collectgarbage("collect")
        t.assertTrue(bound:close():is_retired())
        t.assertNil(f.uv.files[f.uv.alias])
    end
    completed_binding()
    collectgarbage("collect")
    collectgarbage("collect")
    t.assertNil(next(watched))
end

return M
