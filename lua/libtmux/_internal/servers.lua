local defaults = require("libtmux._internal.defaults")
local errors = require("libtmux._internal.error")
local endpoints = require("libtmux._internal.endpoint")
local lifecycle = require("libtmux._internal.lifecycle")
local process = require("libtmux._internal.process")
local server = require("libtmux._internal.server")
local M = {}

local function failure(code, message, cause)
    return errors.new(code, message, { operation = "servers", effect = "not_sent", cause = cause })
end

local function same(first, second)
    return first
        and second
        and first.type == second.type
        and first.dev == second.dev
        and first.ino == second.ino
end

local function prepare_directory(uv, endpoint)
    if endpoint.root then
        local root, cause = uv.fs_stat(endpoint.root)
        if not root or root.type ~= "directory" then
            return nil,
                failure(
                    "invalid_endpoint",
                    "named socket root is not an accessible directory",
                    cause
                )
        end
        local directory = endpoint.root .. "/tmux-" .. string.format("%.0f", endpoint.uid)
        local made, err = uv.fs_mkdir(directory, 448)
        if not made and not tostring(err):match("^EEXIST") then
            return nil, failure("filesystem_error", "cannot prepare named socket directory", err)
        end
        local stat = uv.fs_lstat(directory)
        if
            not stat
            or stat.type ~= "directory"
            or stat.uid ~= endpoint.uid
            or stat.mode % 8 ~= 0
        then
            return nil,
                failure(
                    "invalid_endpoint",
                    "named socket directory needs current UID and no other-user permissions"
                )
        end
    end
    local parent = endpoint.socket:match("^(.*)/[^/]+$")
    local stat, cause = uv.fs_stat(parent == "" and "/" or parent)
    if not stat or stat.type ~= "directory" then
        return nil, failure("invalid_endpoint", "socket parent must already exist", cause)
    end
    return parent == "" and "/" or parent
end

local function owned_process(runtime, endpoint, parent)
    local uv = runtime._driver.uv
    local directory, err = uv.fs_mkdtemp(parent .. "/libtmux-lua-start-XXXXXX")
    if not directory then
        return nil, failure("filesystem_error", "cannot allocate private server startup path", err)
    end
    local directory_stat = uv.fs_lstat(directory)
    local state =
        { directory = directory, private = directory .. "/s", listeners = {}, endpoint = endpoint }
    local lease, cleanup
    local function remove_paths()
        if state.released then
            return true
        end
        if not state.exited and state.child then
            return nil, failure("cleanup_failed", "daemon exit is unproved; startup paths retained")
        end
        if state.child and state.exited and not state.socket_stat then
            -- Cancellation may precede socket creation. The exact native child
            -- has now exited, so inspect only its private, unpublished path in
            -- the unchanged directory allocated for that child.
            local directory_now = uv.fs_lstat(state.directory)
            local late_socket = uv.fs_lstat(state.private)
            if
                same(directory_now, directory_stat)
                and late_socket
                and late_socket.type == "socket"
            then
                state.socket_stat = late_socket
            end
        end
        -- The published alias is shared with other publishers. A pathname
        -- check cannot make unlink atomic; leave that alias to its directory
        -- owner, even when it still refers to our retired daemon.
        for _, path in ipairs({ state.private }) do
            local stat, cause = uv.fs_lstat(path)
            if stat and same(stat, state.socket_stat) then
                local removed, remove_error = uv.fs_unlink(path)
                if not removed then
                    return nil,
                        failure("cleanup_failed", "cannot remove owned socket link", remove_error)
                end
            elseif not stat and not tostring(cause):match("^ENOENT") then
                return nil, failure("cleanup_failed", "cannot inspect owned socket link", cause)
            end
        end
        local stat, cause = uv.fs_lstat(state.directory)
        if not stat and tostring(cause):match("^ENOENT") then
            return true
        end
        if not same(stat, directory_stat) then
            return nil,
                failure("cleanup_failed", "startup directory identity changed; retaining path")
        end
        local removed, remove_error = uv.fs_rmdir(state.directory)
        if not removed then
            return nil, failure("cleanup_failed", "cannot remove startup directory", remove_error)
        end
        return true
    end
    local function finish()
        if
            not state.cleaning
            or (state.child and not state.exited and not state.released and not state.expired)
        then
            return
        end
        if state.timer then
            state.timer:stop()
            state.timer:close()
            state.timer = nil
        end
        local value, cause = remove_paths()
        local listeners = state.listeners
        state.listeners, state.cleaning = {}, false
        local function deliver()
            for _, done in ipairs(listeners) do
                done(value and nil or cause)
            end
        end
        if state.child and not state.exited and not state.released then
            state.child:unref()
            deliver()
        elseif state.child and not state.handle_closed then
            state.handle_closed = true
            state.child:close(deliver)
        else
            deliver()
        end
    end
    cleanup = function(done)
        state.listeners[#state.listeners + 1] = done
        if state.cleaning then
            return
        end
        state.cleaning, state.expired = true, false
        if not state.child or state.exited or state.released then
            finish()
            return
        end
        if not state.socket_stat then
            local stat = uv.fs_lstat(state.private)
            if stat and stat.type == "socket" then
                state.socket_stat = stat
            end
        end
        state.child:ref()
        local sent, cause = state.child:kill("sigterm")
        if not sent then
            state.signal_error = cause
        end
        state.timer = uv.new_timer()
        state.timer:start(100, 0, function()
            if not state.exited then
                state.child:kill("sigkill")
            end
            if state.timer then
                state.timer:start(500, 0, function()
                    state.expired = true
                    finish()
                end)
            end
        end)
    end
    lease, err = runtime:_resource(cleanup)
    if not lease then
        uv.fs_rmdir(directory)
        return nil, err
    end
    state.lease = lease
    state.child, state.pid = uv.spawn(endpoint.binary, {
        args = { "-D", "-u", "-f", endpoint.config, "-S", state.private },
        env = endpoint.env,
        stdio = { nil, nil, nil },
    }, function(code, signal)
        state.exited, state.exit_code, state.exit_signal = true, code, signal
        finish()
    end)
    if not state.child then
        state.exited = true
        lease:close()
        return nil, failure("spawn_failed", "cannot start foreground tmux daemon", state.pid)
    end
    function state.retire()
        return runtime:_request({
            bytes = 0,
            operation = "server.retire",
            timeout = 750,
            start = function(settle, retire)
                cleanup(function(cause)
                    settle(cause == nil and true or nil, cause)
                    retire()
                end)
                -- Retirement continues after waiter cancellation; the lease retains it.
                return function() end
            end,
        })
    end
    return state
end

local function socket_ready(runtime, state)
    return runtime:_request({
        bytes = 0,
        operation = "server.start",
        timeout = 750,
        start = function(settle, retire)
            local uv, finished = runtime._driver.uv, false
            local timer = uv.new_timer()
            local function finish(value, err)
                if finished then
                    return
                end
                finished = true
                timer:stop()
                timer:close(function()
                    retire()
                end)
                settle(value, err)
            end
            timer:start(0, 5, function()
                if state.exited then
                    finish(
                        nil,
                        failure("startup_failed", "foreground tmux exited before socket readiness")
                    )
                    return
                end
                local stat, cause = uv.fs_lstat(state.private)
                if stat and stat.type == "socket" then
                    state.socket_stat = stat
                    finish(true)
                elseif stat or not tostring(cause):match("^ENOENT") then
                    finish(
                        nil,
                        failure("startup_failed", "private startup endpoint is not a socket", cause)
                    )
                end
            end)
            return function(err)
                finish(nil, err)
            end
        end,
    })
end

local function ready(runtime, state)
    local deadline = runtime._driver.now() + 750
    return runtime:_operation(function(rt)
        local available, err = socket_ready(rt, state):await()
        if not available then
            return nil, err
        end
        local endpoint = state.endpoint
        local result
        repeat
            if state.exited then
                return nil, failure("startup_failed", "foreground daemon exited before readiness")
            end
            result, err = process
                .execute(rt, {
                    endpoint.binary,
                    "-N",
                    "-u",
                    "-S",
                    state.private,
                    "display-message",
                    "-p",
                    "#{pid}",
                }, {
                    env = endpoint.env,
                    deadline = deadline,
                    max_output_bytes = 4096,
                })
                :await()
            if
                result
                and result.exit_code == 0
                and result.stderr == ""
                and result.stdout == tostring(state.pid) .. "\n"
            then
                return true
            end
        -- A socket inode can appear before tmux starts accepting clients.
        -- Each no-start probe yields through the native process adapter.
        until rt._driver.now() >= deadline
        return nil, failure("startup_failed", "daemon did not confirm its native child PID", err)
    end, { operation = "server.ready", effect = "not_sent" })
end

function M.start(runtime, options, find, resolved)
    local endpoint, validation_error
    if resolved then
        endpoint = options
    else
        endpoint, validation_error = defaults.resolve(runtime._driver.uv, options)
    end
    local holder = {}
    local registered, registration_error = runtime:defer(function()
        if holder.owner then
            return holder.owner:close():await()
        end
        return true
    end)
    return runtime:_operation(function(rt)
        if not registered then
            return nil, registration_error
        end
        if not endpoint then
            return nil, validation_error
        end
        local uv = rt._driver.uv
        local parent, err = prepare_directory(uv, endpoint)
        if not parent then
            return nil, err
        end
        local existing, cause = uv.fs_lstat(endpoint.socket)
        if existing then
            if not find then
                return nil, failure("already_exists", "owned_server requires an unused socket path")
            end
            local borrowed
            borrowed, err = server.resolved(rt, endpoint):await()
            if not borrowed then
                return nil, err
            end
            return { value = borrowed, created = false }
        elseif not tostring(cause):match("^ENOENT") then
            return nil, failure("filesystem_error", "cannot inspect selected socket", cause)
        end
        local process_state, delivered
        local deferred
        deferred, err = rt:defer(function()
            if process_state and not delivered then
                return process_state.retire():await()
            end
            return true
        end)
        if not deferred then
            return nil, err
        end
        process_state, err = owned_process(rt, endpoint, parent)
        if not process_state then
            return nil, err
        end
        local started
        started, err = ready(rt, process_state):await()
        if not started then
            return nil, err
        end
        local linked, link_error = uv.fs_link(process_state.private, endpoint.socket)
        if not linked then
            if find and tostring(link_error):match("^EEXIST") then
                local cleaned
                cleaned, err = process_state.retire():await()
                if not cleaned then
                    return nil, err
                end
                local borrowed
                borrowed, err = server.resolved(rt, endpoint):await()
                if not borrowed then
                    return nil, err
                end
                return { value = borrowed, created = false }
            end
            return nil, failure("publish_failed", "cannot claim selected socket path", link_error)
        end
        -- Only our allocated private route can authorize startup ownership.
        -- The published alias may already point to another daemon.
        local private_endpoint = {}
        for key, value in pairs(endpoint) do
            private_endpoint[key] = value
        end
        private_endpoint.socket, private_endpoint.pin_parent = process_state.private, parent
        local connected
        connected, err = server.resolved(rt, private_endpoint):await()
        if not connected then
            return nil, err
        end
        local owner
        owner, err = connected:adopt():await()
        if not owner then
            return nil, err
        end
        if owner:receipt().pid ~= tostring(process_state.pid) then
            owner:release()
            return nil,
                failure("stale_generation", "private socket does not identify the spawned daemon")
        end
        lifecycle.attach(owner, process_state.retire, function()
            process_state.released = true
        end)
        holder.owner = lifecycle.transfer(owner)
        delivered = true
        if find then
            return { value = connected, created = true, owner = holder.owner }
        end
        return holder.owner
    end, { operation = find and "find_or_create_server" or "owned_server", effect = "not_sent" })
end

function M.scope(runtime, options, body)
    local endpoint, err = defaults.resolve(runtime._driver.uv, options)
    return runtime:_operation(function()
        if not endpoint then
            return nil, err
        end
        if type(body) ~= "function" then
            return nil, failure("invalid_callback", "server scope requires a function")
        end
        local owner, cause = M.start(runtime, endpoint, false, true):await()
        if not owner then
            return nil, cause
        end
        return body(owner.value, owner)
    end, { operation = "owned_scope", effect = "not_sent" })
end

function M.discover(runtime, options)
    options = options or {}
    local validation_error, copied, resolve_options = nil, {}, {}
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        validation_error = failure("invalid_options", "discovery options must be a plain record")
    else
        local accepted = {
            roots = true,
            paths = true,
            max_entries = true,
            max_probes = true,
            timeout = true,
            binary = true,
            client_env = true,
            env = true,
        }
        for key, value in pairs(options) do
            if not accepted[key] then
                validation_error = failure("invalid_options", "unknown discovery option")
            end
            if key == "binary" or key == "client_env" or key == "env" then
                resolve_options[key] = value
            else
                copied[key] = value
            end
        end
    end
    local endpoint, endpoint_error = defaults.resolve(runtime._driver.uv, resolve_options)
    for key, default in pairs({ max_entries = 256, max_probes = 32, timeout = 2000 }) do
        copied[key] = copied[key] == nil and default or copied[key]
        if
            type(copied[key]) ~= "number"
            or copied[key] < 1
            or copied[key] > (key == "timeout" and 60000 or 4096)
            or copied[key] % 1 ~= 0
        then
            validation_error =
                failure("invalid_options", "discovery limits must be positive bounded integers")
        end
    end
    for _, key in ipairs({ "roots", "paths" }) do
        if copied[key] ~= nil then
            if type(copied[key]) ~= "table" or getmetatable(copied[key]) ~= nil then
                validation_error =
                    failure("invalid_options", "discovery roots and paths must be dense sequences")
            else
                local list, count = {}, 0
                for index, value in pairs(copied[key]) do
                    count = count + 1
                    if
                        type(index) ~= "number"
                        or index < 1
                        or index % 1 ~= 0
                        or type(value) ~= "string"
                        or value:sub(1, 1) ~= "/"
                        or #value > 4096
                        or value:find("\000", 1, true)
                    then
                        validation_error =
                            failure("invalid_options", "discovery needs absolute bounded paths")
                    else
                        list[index] = value
                    end
                end
                if count > 32 or count ~= #list then
                    validation_error = failure(
                        "invalid_options",
                        "discovery accepts at most 32 dense roots or paths"
                    )
                end
                copied[key] = list
            end
        end
    end
    if endpoint and copied.roots == nil then
        local root = defaults.socket_root(endpoint.env)
        if root:sub(1, 1) ~= "/" then
            validation_error = failure("invalid_options", "discovery TMUX_TMPDIR must be absolute")
        end
        local suffix = "/tmux-" .. tostring(runtime._driver.uv.getuid())
        copied.roots = { root .. suffix }
        if root ~= "/tmp" then
            copied.roots[#copied.roots + 1] = "/tmp" .. suffix
        end
    end
    return runtime:_operation(function(rt)
        if validation_error then
            return nil, validation_error
        end
        if not endpoint then
            return nil, endpoint_error
        end
        local uv, result, candidates, seen, identities =
            rt._driver.uv,
            { servers = {}, diagnostics = {}, truncated = false, entries = 0, probes = 0 },
            {},
            {},
            {}
        local deadline = rt._driver.now() + copied.timeout
        local function diagnostic(path, code, cause)
            result.diagnostics[#result.diagnostics + 1] =
                { path = path, code = code, cause = cause }
        end
        local function candidate(path)
            if not seen[path] then
                seen[path] = true
                candidates[#candidates + 1] = path
            end
        end
        for _, path in ipairs(copied.paths or {}) do
            candidate(path)
        end
        for _, root in ipairs(copied.roots or {}) do
            local stat, cause = uv.fs_lstat(root)
            if not stat or stat.type ~= "directory" or stat.uid ~= uv.getuid() then
                diagnostic(root, "invalid_root", cause)
            else
                local scan, scan_error = uv.fs_opendir(root, nil, 16)
                if not scan then
                    diagnostic(root, "scan_failed", scan_error)
                else
                    local stop = false
                    while not stop do
                        local entries, read_error = uv.fs_readdir(scan)
                        if not entries then
                            if read_error then
                                diagnostic(root, "scan_failed", read_error)
                            end
                            break
                        end
                        for _, entry in ipairs(entries) do
                            if
                                result.entries >= copied.max_entries
                                or rt._driver.now() >= deadline
                            then
                                result.truncated, stop = true, true
                                break
                            end
                            result.entries = result.entries + 1
                            if entry.type == "socket" or entry.type == "unknown" then
                                candidate(root .. "/" .. entry.name)
                            end
                        end
                    end
                    local closed, close_error = uv.fs_closedir(scan)
                    if not closed then
                        diagnostic(root, "scan_close_failed", close_error)
                    end
                end
            end
        end
        table.sort(candidates)
        for _, path in ipairs(candidates) do
            if result.probes >= copied.max_probes or rt._driver.now() >= deadline then
                result.truncated = true
                break
            end
            local stat, cause = uv.fs_lstat(path)
            if not stat or stat.type ~= "socket" or stat.uid ~= uv.getuid() then
                diagnostic(path, "invalid_socket", cause)
            elseif identities[tostring(stat.dev) .. ":" .. tostring(stat.ino)] then
                diagnostic(path, "duplicate_socket")
            else
                identities[tostring(stat.dev) .. ":" .. tostring(stat.ino)] = true
                result.probes = result.probes + 1
                local probe = {
                    binary = endpoint.binary,
                    socket = path,
                    config = endpoint.config,
                    env = endpoint.env,
                }
                local bound, err = endpoints.bind(rt, probe):await()
                if bound then
                    local evidence = bound:evidence()
                    result.servers[#result.servers + 1] = {
                        socket_path = path,
                        pid = evidence.pid,
                        started = evidence.started,
                        version = evidence.version,
                    }
                    local closed, close_error = bound:close():await()
                    if not closed then
                        diagnostic(path, "cleanup_failed", close_error)
                    end
                else
                    diagnostic(path, "probe_failed", err)
                end
            end
        end
        return result
    end, { operation = "discover_servers", effect = "not_sent" })
end

---@class libtmux.DiscoveryOptions
---@field roots? string[] Socket directories; defaults to captured TMUX_TMPDIR and /tmp UID roots.
---@field paths? string[] Additional exact paths, at most 32.
---@field max_entries? integer Defaults to 256.
---@field max_probes? integer Defaults to 32.
---@field timeout? integer Milliseconds; checked between bounded 750 ms probes.
---@field binary? string
---@field client_env? table<string,string|false>
---@field env? string[] Complete child environment; excludes client_env.

---@class libtmux.DiscoveredServer
---@field socket_path string
---@field pid string
---@field started string
---@field version string

---@class libtmux.DiscoveryResult
---@field servers libtmux.DiscoveredServer[]
---@field diagnostics table[] Per-root and per-path failures, exclusions and duplicate sockets.
---@field entries integer
---@field probes integer
---@field truncated boolean

return M
