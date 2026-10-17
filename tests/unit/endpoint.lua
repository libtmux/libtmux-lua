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
        local last = spec.args[#spec.args]
        local metadata = last:match("^libtmux%-version%-[0-9a-f]+%-") ~= nil
        local function finish()
            if not metadata and uv.dead_listener then
                spec.stdio[3].read(nil, "no server running on /owned/tmux.sock\n")
            elseif not metadata and uv.fence_refused then
                for _, word in ipairs(spec.args) do
                    if word:match("^libtmux%-version%-%x+%-$") then
                        spec.stdio[3].read(nil, "unknown command: " .. word .. "\n")
                    end
                end
            elseif not metadata then
                spec.stdio[2].read(nil, "done\n")
            elseif uv.probe_reply then
                local prefix = last:match("^(libtmux%-version%-[0-9a-f]+%-)")
                spec.stdio[2].read(nil, uv.probe_stdout or "")
                spec.stdio[3].read(nil, uv.probe_reply(prefix))
            elseif not uv.dead_listener then
                local prefix = last:match("^(libtmux%-version%-[0-9a-f]+%-)")
                spec.stdio[3].read(
                    nil,
                    "unknown command: "
                        .. prefix
                        .. "123_100_"
                        .. (uv.daemon_version or "3.7c")
                        .. "_/owned/tmux.sock.\n"
                )
            elseif uv.evidence_stderr then
                spec.stdio[3].read(nil, uv.evidence_stderr)
            end
            spec.stdio[2].read(nil, nil)
            spec.stdio[3].read(nil, nil)
            on_exit(
                metadata and (uv.probe_exit or 1)
                    or (uv.fence_refused or uv.dead_listener) and 1
                    or uv.exit_code
                    or 0,
                0
            )
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

function M.test_only_the_exact_probe_report_is_daemon_evidence()
    local replies = {
        ["silent failure"] = function()
            return ""
        end,
        ["absent server"] = function()
            return "no server running on /owned/tmux.sock\n"
        end,
        ["other marker"] = function()
            return "unknown command: libtmux-version-0000000000000000-123_100_3.7c_/s.\n"
        end,
        ["prefix only"] = function(prefix)
            return "unknown command: " .. prefix .. "\n"
        end,
        ["unterminated record"] = function(prefix)
            return "unknown command: " .. prefix .. "123_100_3.7c_/owned/tmux.sock\n"
        end,
        ["newline in socket path"] = function(prefix)
            return "unknown command: " .. prefix .. "123_100_3.7c_/owned/a\nb.\n"
        end,
        ["extra stderr line"] = function(prefix)
            return "unknown command: " .. prefix .. "123_100_3.7c_/s.\nnoise\n"
        end,
        ["zero pid"] = function(prefix)
            return "unknown command: " .. prefix .. "0_100_3.7c_/s.\n"
        end,
    }
    for name, reply in pairs(replies) do
        local f = fixture()
        f.uv.probe_reply = reply
        f:start(function(rt)
            local bound, err =
                endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
            t.assertNil(bound, name)
            t.assertEquals(assert(err).code, "uncertain_generation", name)
            t.assertEquals(err.effect, "not_sent", name)
        end)
        t.assertNil(f.uv.files[f.uv.alias], name)
    end
    local f = fixture()
    f.uv.probe_reply, f.uv.probe_exit, f.uv.probe_stdout =
        function(prefix)
            return "unknown command: " .. prefix .. "123_100_3.7c_/s.\n"
        end, 0, "ran\n"
    f:start(function(rt)
        local bound, err =
            endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
        t.assertNil(bound)
        t.assertEquals(assert(err).code, "uncertain_generation")
    end)
end

function M.test_daemon_release_is_admitted_from_the_probe_not_the_client()
    local supported = { "3.3a", "3.4", "3.7c", "3.10", "next-3.9", "3.8-rc2" }
    local refused = { "3.2a", "3.3", "3.2", "next-3.3a", "3.3a-rc1", "master", "openbsd-7.6" }
    for _, version in ipairs(supported) do
        local f = fixture()
        f.uv.daemon_version = version
        f:start(function(rt)
            local bound, err =
                endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
            t.assertNotNil(bound, version .. tostring(err))
            t.assertEquals(assert(bound:evidence()).version, version)
        end)
    end
    for _, version in ipairs(refused) do
        local f = fixture()
        f.uv.daemon_version = version
        f:start(function(rt)
            local bound, err =
                endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
            t.assertNil(bound, version)
            t.assertEquals(assert(err).code, "unsupported_version", version)
            t.assertEquals(err.effect, "not_sent", version)
            -- Only the probe ran: no command reached the refused daemon.
            t.assertEquals(#f.uv.spawned, 1, version)
        end)
        t.assertNil(f.uv.files[f.uv.alias], version)
    end
end

function M.test_probe_names_a_fresh_marker_and_never_runs_display_message()
    local f = fixture()
    f:start(function(rt)
        local bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        assert(bound:execute({ "display-message", "-p", "done" }):await())
        local markers = {}
        for _, spawn in ipairs(f.uv.spawned) do
            local last = spawn.args[#spawn.args]
            local marker = last:match("^(libtmux%-version%-%x+%-)#")
            if marker then
                t.assertEquals(spawn.args[#spawn.args - 2], "run-shell")
                t.assertEquals(spawn.args[#spawn.args - 1], "-C")
                t.assertNil(markers[marker])
                markers[marker] = true
            else
                t.assertEquals(spawn.args[#spawn.args - 2], "display-message")
            end
        end
        t.assertEquals(next(markers) ~= nil, true)
    end)
end

function M.test_every_dispatch_is_fenced_on_the_admitted_release()
    local f = fixture()
    f:start(function(rt)
        local bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        assert(bound:execute({ "display-message", "-p", "one" }):await())
        assert(bound:group({ { "new-window", "-d" }, { "rename-window", "x" } }):await())
        local seen = {}
        for _, spawn in ipairs(f.uv.spawned) do
            local args = spawn.args
            local dash = 1
            while args[dash] ~= "--" do
                dash = dash + 1
            end
            if args[dash + 1] == "if-shell" then
                seen[#seen + 1] = args
                t.assertEquals(args[dash + 2], "-F")
                t.assertEquals(
                    args[dash + 3],
                    "#{&&:#{==:#{pid},123},#{&&:#{==:#{start_time},100},#{==:#{version},3.7c}}}"
                )
                t.assertEquals(args[dash + 4], "")
                t.assertNotNil(args[dash + 5]:match("^libtmux%-version%-%x+%-$"))
                t.assertEquals(args[dash + 6], ";")
            end
        end
        t.assertEquals(#seen, 2)
        -- The checked version is cached: the binding probe is the only probe.
        t.assertEquals(#f.uv.spawned, 3)
        t.assertEquals(seen[1][#seen[1]], "one")
        t.assertEquals(table.concat(seen[2], " ", #seen[2] - 4), "new-window -d ; rename-window x")
        t.assertNotEquals(seen[1][#seen[1] - 4], seen[2][#seen[2] - 10])
    end)
end

function M.test_fence_refusal_reports_a_replaced_daemon_and_pins_nothing_further()
    for _, group in ipairs({ false, true }) do
        local f = fixture()
        f:start(function(rt)
            local bound = assert(
                endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
            )
            local generation = assert(bound:generation())
            f.uv.fence_refused = true
            local argv = { "new-session", "-d", "-s", "must-not-exist" }
            local value, err
            if group then
                value, err = bound:group({ argv }):await()
            else
                value, err = bound:execute(argv):await()
            end
            t.assertNil(value)
            t.assertEquals(assert(err).code, "stale_generation")
            t.assertEquals(err.effect, "not_sent")
            -- The refusal came from the dispatched command, not a probe.
            t.assertEquals(#f.uv.spawned, 2)
            f.uv.fence_refused = false
            t.assertNil(bound:generation())
            t.assertNil(identity.evidence(generation))
            -- The fence dropped the cached version: the next call dispatches nothing.
            local again, again_error = bound:execute({ "display-message", "-p", "late" }):await()
            t.assertNil(again)
            t.assertEquals(assert(again_error).code, "stale_generation")
            t.assertEquals(#f.uv.spawned, 2)
        end)
    end
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
        t.assertEquals(f.uv.spawned[2].program, "/actual/tmux")
        t.assertEquals(f.uv.spawned[2].args[2], f.uv.alias)
        t.assertNotNil(table.concat(f.uv.spawned[2].args, " "):find(" -N ", 1, true))
        f.uv.files["/owned/tmux.sock"] = { type = "socket", dev = 1, ino = 20 }
        result, err = bound:execute({ "kill-session", "-t", "$0" }):await()
        t.assertNil(result)
        assert(err)
        t.assertEquals(err.code, "stale_generation")
        t.assertEquals(err.effect, "not_sent")
        t.assertEquals(#f.uv.spawned, 2)
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

function M.test_persistent_startup_cleanup_barrier_waits_for_native_retirement()
    for _, outcome in ipairs({ "cancelled", "failed", "discarded" }) do
        local f = fixture()
        local finish, release_root, retire_root, cleanup, closed
        closed = 0
        f:start(function(rt)
            f.bound = assert(
                endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await()
            )
            f.opening, cleanup = f.bound:_client(function()
                if outcome == "cancelled" then
                    return rt:_logical_request({
                        start = function(_, retire)
                            return function()
                                retire()
                            end
                        end,
                    }):await()
                elseif outcome == "failed" then
                    return nil, { code = "startup_failed" }
                end
                return "discarded connection"
            end, function(done)
                closed, finish = closed + 1, done
            end)
            f.opening:await()
            rt:_logical_request({
                start = function(settle, retire)
                    release_root, retire_root = settle, retire
                end,
            }):await()
        end)
        t.assertEquals(type(cleanup), "function", "startup cleanup barrier is missing")
        if outcome == "cancelled" then
            local value, err = cleanup()
            t.assertNil(value)
            t.assertEquals(assert(err).code, "pending")
            t.assertEquals(closed, 0)
            f.opening:cancel()
            f.driver:drain()
        end
        t.assertTrue(f.opening:is_retired())
        local barrier = assert(cleanup())
        t.assertIs(cleanup(), barrier)
        t.assertFalse(barrier:cancel())
        f.driver:drain()
        t.assertEquals(closed, 1)
        t.assertFalse(barrier:is_retired())
        t.assertFalse(f.root:is_retired())
        t.assertNotNil(f.uv.files[f.uv.alias])
        finish()
        f.driver:drain()
        t.assertTrue(barrier:is_retired())
        t.assertTrue(barrier:result())
        release_root(true)
        retire_root()
        f.driver:drain()
        t.assertTrue(f.root:is_retired())
        t.assertNil(f.uv.files[f.uv.alias])
        t.assertEquals(f.runtime:stats().resources, 0)
    end
end

function M.test_persistent_startup_cancel_before_allocation_has_no_cleanup_barrier()
    local f = fixture()
    local opened, closed = false, false
    f:start(function(rt)
        local bound =
            assert(endpoints.bind(rt, { binary = "/tmux", socket = "/owned/tmux.sock" }):await())
        local before = #f.uv.spawned
        local opening, cleanup = bound:_client(function()
            opened = true
        end, function(done)
            closed = true
            done()
        end)
        t.assertEquals(type(cleanup), "function", "startup cleanup barrier is missing")
        local value, err = cleanup()
        t.assertNil(value)
        t.assertEquals(assert(err).code, "pending")
        t.assertTrue(opening:cancel())
        t.assertTrue(opening:is_retired())
        value, err = cleanup()
        t.assertNil(value)
        t.assertNil(err)
        t.assertEquals(#f.uv.spawned, before)
    end)
    t.assertFalse(opened)
    t.assertFalse(closed)
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
        -- The bind probe and the one dispatch that found no daemon.
        t.assertEquals(#f.uv.spawned, 2)
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
        f.uv.dead_listener = true
        local request = bound:group({ { "display-message" } })
        local initial = request._cost
        local absent = "no server running on /owned/tmux.sock\n"
        request:on_complete(function(value, err)
            t.assertNil(value)
            t.assertEquals(err.cause.partial.stderr, absent)
            t.assertEquals(rt:stats().bytes, initial + #absent)
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
