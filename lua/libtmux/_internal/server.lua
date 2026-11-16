local settings = require("libtmux._internal.settings")
local environment = require("libtmux._internal.environment")
local buffer = require("libtmux._internal.buffer")
local client = require("libtmux._internal.client")
local command = require("libtmux._internal.command")
local endpoints = require("libtmux._internal.endpoint")
local errors = require("libtmux._internal.error")
local fields = require("libtmux._internal.fields")
local graph = require("libtmux._internal.graph")
local metadata = require("libtmux._internal.metadata")
local entities = require("libtmux._internal.entity")
local execution = require("libtmux._internal.execution")
local process = require("libtmux._internal.process")
local domain = require("libtmux._internal.domain")
local live_query = require("libtmux._internal.live_query")
local observation = require("libtmux._internal.observation")
local capability_registry = require("libtmux._internal.support.capabilities")
local M, Server = {}, {}
-- Live objects own state; the registry must not root returned-request cycles on Lua 5.1.
local servers = setmetatable({}, { __mode = "kv" })
local specs = {
    { "session", "sessions", "list-sessions", { "id", "name" } },
    { "window", "windows", "list-windows", { "id" }, "-a" },
    { "pane", "panes", "list-panes", { "id", "window_id", "index" }, "-a" },
    { "window_link", "window_links", "list-windows", { "session_id", "window_id", "index" }, "-a" },
    { "client", "clients", "list-clients", { "name", "tty", "session_name" } },
    { "buffer", "buffers", "list-buffers", { "name" } },
}

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function failure(code, message, details)
    details = details or {}
    details.operation, details.effect = "snapshot", details.effect or "not_sent"
    return errors.new(code, message, details)
end

local function integer(value, maximum)
    return type(value) == "number" and value >= 1 and value <= maximum and value % 1 == 0
end

local function connection_options(options)
    if not plain(options) then
        return nil, failure("invalid_options", "connection options must be a plain record")
    end
    local copied, mapping =
        {}, { binary = "binary", socket_path = "socket", config_path = "config" }
    for key, value in next, options do
        if not mapping[key] then
            return nil, failure("invalid_options", "unknown connection option")
        end
        copied[mapping[key]] = value
    end
    return copied
end

local function capture_options(state, options)
    options = options == nil and {} or options
    if not plain(options) then
        return nil, failure("invalid_options", "snapshot options must be a plain record")
    end
    local allowed =
        { strict = true, fields = true, max_rows = true, max_bytes = true, timeout = true }
    for key in next, options do
        if not allowed[key] then
            return nil, failure("invalid_options", "unknown snapshot option")
        end
    end
    local result = {
        strict = options.strict,
        max_rows = options.max_rows == nil and 65536 or options.max_rows,
        max_bytes = options.max_bytes == nil and 16 * 1024 * 1024 or options.max_bytes,
        timeout = options.timeout == nil and 750 or options.timeout,
        projections = {},
        requested = {},
        effective = {},
        capabilities = {},
    }
    if result.strict == nil then
        result.strict = false
    end
    if
        type(result.strict) ~= "boolean"
        or not integer(result.max_rows, 65536)
        or not integer(result.max_bytes, 2147483647)
        or not integer(result.timeout, 2147483647)
    then
        return nil, failure("invalid_options", "snapshot limits or strict mode are invalid")
    end
    local selected = options.fields == nil and {} or options.fields
    if not plain(selected) then
        return nil,
            failure("invalid_options", "snapshot fields must map collection names to sequences")
    end
    local known = {}
    for _, spec in ipairs(specs) do
        known[spec[2]] = true
    end
    for key in next, selected do
        if not known[key] then
            return nil, failure("invalid_options", "unknown snapshot collection")
        end
    end
    for _, spec in ipairs(specs) do
        local kind, name = spec[1], spec[2]
        local schema, err = fields.schema(kind, state.version)
        if not schema then
            return nil, err
        end
        local names = selected[name]
        local capabilities = {}
        for key, definition in pairs(schema.fields) do
            capabilities[key] = definition.supported
        end
        result.capabilities[kind] = capabilities
        if names == nil then
            names = {}
            for key, supported in pairs(capabilities) do
                if supported then
                    names[#names + 1] = key
                end
            end
            table.sort(names)
        end
        local projection
        projection, err = metadata.projection(kind, state.version, names)
        if not projection then
            return nil, err
        end
        local requested, effective, seen = {}, {}, {}
        for index, key in ipairs(names) do
            requested[index], effective[index], seen[key] = key, key, true
        end
        for _, key in ipairs(spec[4]) do
            if not seen[key] then
                effective[#effective + 1] = key
            end
        end
        projection, err = metadata.projection(kind, state.version, effective)
        if not projection then
            return nil, err
        end
        result.requested[kind], result.effective[kind], result.projections[kind] =
            requested, effective, projection
    end
    return result
end

local function listing_argv(spec, projection)
    local argv = { spec[3] }
    if spec[5] then
        argv[#argv + 1] = spec[5]
    end
    argv[#argv + 1], argv[#argv + 2] = "-F", assert(metadata.format(projection))
    return argv
end

local function capture_commands(state, options)
    local commands = {}
    for pass = 1, options.strict and 2 or 1 do
        for _, spec in ipairs(specs) do
            local projection = pass == 2
                    and assert(metadata.projection(spec[1], state.version, spec[4]))
                or options.projections[spec[1]]
            commands[#commands + 1] = {
                role = pass == 2 and "verify" or "hydrate",
                kind = spec[1],
                argv = listing_argv(spec, projection),
            }
        end
    end
    return commands
end

local function acquire(state, options, operation, verification)
    local listings, rows_seen, bytes_seen, retained_seen = {}, 0, 0, 0
    for _, spec in ipairs(specs) do
        local kind, name = spec[1], spec[2]
        -- tmux has no current target for these listings on a sessionless daemon.
        if kind ~= "session" and kind ~= "buffer" and #listings.sessions == 0 then
            listings[name] = {}
        else
            local projection = options.projections[kind]
            if verification then
                projection = assert(metadata.projection(kind, state.version, spec[4]))
            end
            local argv = listing_argv(spec, projection)
            local result, err = state.bound
                :execute(argv, {
                    timeout = options.timeout,
                    max_output_bytes = math.max(1, options.max_bytes - bytes_seen),
                })
                :await()
            if not result then
                return process.retain_output(operation, nil, err, "snapshot")
            end
            bytes_seen = bytes_seen + #result.stdout
            if bytes_seen > options.max_bytes then
                return nil,
                    failure(
                        "snapshot_limit",
                        "snapshot exceeds its total encoded byte limit",
                        { effect = "completed" }
                    )
            end
            local rows
            rows, err = metadata.decode(result.stdout, projection, {
                max_rows = math.max(1, options.max_rows - rows_seen),
                max_bytes = options.max_bytes,
            })
            if not rows then
                assert(err)
                if err.code == "frame_limit" then
                    return nil,
                        failure(
                            "snapshot_limit",
                            "snapshot exceeds its acquisition limit",
                            { cause = err, effect = "completed" }
                        )
                end
                return nil, failure(err.code, err.message, { cause = err, effect = "completed" })
            end
            rows_seen = rows_seen + #rows
            if rows_seen > options.max_rows then
                return nil,
                    failure(
                        "snapshot_limit",
                        "snapshot exceeds its total row limit",
                        { effect = "completed" }
                    )
            end
            local retained = 0
            for _, row in ipairs(rows) do
                for key, value in pairs(row) do
                    retained = retained + #key + (type(value) == "string" and #value or 8)
                end
            end
            retained_seen = retained_seen + retained
            if retained_seen > options.max_bytes then
                return nil,
                    failure(
                        "snapshot_limit",
                        "snapshot exceeds its retained scalar byte limit",
                        { effect = "completed" }
                    )
            end
            local admitted
            admitted, err = operation:_retain(retained * (verification and 1 or 2))
            if not admitted then
                assert(err)
                return nil, failure(err.code, err.message, { cause = err, effect = "completed" })
            end
            listings[name] = rows
        end
    end
    return listings
end

local function topology(listings)
    local result = {}
    for _, spec in ipairs(specs) do
        local seen = {}
        for _, row in ipairs(listings[spec[2]]) do
            local parts = {}
            for _, key in ipairs(spec[4]) do
                local value = row[key]
                local text = type(value) == "table" and "null" or tostring(value)
                parts[#parts + 1] = type(value) .. ":" .. #text .. ":" .. text
            end
            seen[table.concat(parts)] = true
        end
        local keys = {}
        for key in pairs(seen) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        result[spec[2]] = keys
    end
    return result
end

local function same_topology(first, second)
    first, second = topology(first), topology(second)
    for name, keys in pairs(first) do
        if #keys ~= #second[name] then
            return false
        end
        for index, key in ipairs(keys) do
            if key ~= second[name][index] then
                return false
            end
        end
    end
    return true
end

--- Capture explicit data; collection access and filtering perform no I/O.
local function capture(state, options)
    local copied, validation_error = capture_options(state, options)
    return state.runtime:_operation(function(_, operation)
        if state.closed then
            return nil, failure("closed", "server handle is closed")
        end
        if not copied then
            return nil, validation_error
        end
        local started = state.runtime._driver.now()
        operation:_set_effect("unknown")
        local listings, err = acquire(state, copied, operation)
        if not listings then
            return nil, err
        end
        local generation
        generation, err = state.bound:generation()
        if not generation then
            return nil, err
        end
        local snapshot
        snapshot, err = graph.build(generation, listings, {
            started = started,
            finished = state.runtime._driver.now(),
            max_rows = copied.max_rows,
            max_bytes = copied.max_bytes,
        })
        if not snapshot then
            assert(err)
            return nil, failure(err.code, err.message, { cause = err, effect = "completed" })
        end
        snapshot.projections, snapshot.requested_projections = copied.effective, copied.requested
        snapshot.capabilities = { version = state.version, fields = copied.capabilities }
        snapshot.verification = { passes = 0, consistent = nil }
        if copied.strict then
            local verified
            snapshot.verification.passes = 1
            verified, err = acquire(state, copied, operation, true)
            if not verified then
                snapshot.complete = false
                snapshot.verification.consistent = false
                snapshot.races[#snapshot.races + 1] = { code = "verification_failed" }
                return nil,
                    failure(
                        "inconsistent_snapshot",
                        "snapshot verification failed",
                        { cause = err, partial = snapshot, effect = "unknown" }
                    )
            end
            snapshot.verification.consistent = same_topology(listings, verified)
            snapshot.acquisition.finished = state.runtime._driver.now()
            if not snapshot.verification.consistent then
                snapshot.complete = false
                snapshot.races[#snapshot.races + 1] = { code = "topology_changed" }
            end
            if not snapshot.complete then
                return nil,
                    failure(
                        "inconsistent_snapshot",
                        "captured topology changed or has inconsistent relationships",
                        { partial = snapshot, effect = "completed" }
                    )
            end
        end
        if state.closed then
            return nil,
                failure(
                    "closed",
                    "server handle closed during capture",
                    { partial = snapshot, effect = "completed" }
                )
        end
        local current
        current, err = state.bound:generation()
        if not current then
            return nil, err
        end
        return snapshot
    end, { operation = "snapshot", effect = "not_sent" })
end

--- Discover feature requirements on this handle's actual pinned daemon.
--- Returns copied feature/workaround metadata. Unknown IDs are absent; edits to a
--- report do not affect admission. The bounded probe creates no tmux resources and
--- refuses a replaced or closed binding. The detached report remains an observation
--- of that release after later daemon changes.
---@return libtmux.Request<libtmux.CapabilityReport>
function Server:capabilities()
    local state = servers[self]
    return state.runtime:_operation(function()
        if state.closed then
            return nil,
                errors.new("closed", "server handle is closed", {
                    operation = "capabilities",
                    effect = "not_sent",
                })
        end
        local evidence, err = state.bound:observe_evidence():await()
        if not evidence then
            return nil, err
        end
        return capability_registry.report(evidence.version)
    end, { operation = "capabilities", effect = "not_sent" })
end

function Server:get_option(name, options)
    return settings.run(servers[self], nil, "option", "get", name, nil, options)
end

function Server:list_options(options)
    return settings.run(servers[self], nil, "option", "list", nil, nil, options)
end

function Server:set_option(name, value, options)
    return settings.run(servers[self], nil, "option", "set", name, value, options)
end

function Server:unset_option(name, options)
    return settings.run(servers[self], nil, "option", "unset", name, nil, options)
end

function Server:get_hook(name, options)
    return settings.run(servers[self], nil, "hook", "get", name, nil, options)
end

function Server:list_hooks(options)
    return settings.run(servers[self], nil, "hook", "list", nil, nil, options)
end

function Server:set_hook(name, value, options)
    return settings.run(servers[self], nil, "hook", "set", name, value, options)
end

function Server:unset_hook(name, options)
    return settings.run(servers[self], nil, "hook", "unset", name, nil, options)
end

function Server:get_environment(name, options)
    return environment.run(servers[self], nil, "get", name, nil, options)
end

function Server:list_environment(options)
    return environment.run(servers[self], nil, "list", nil, nil, options)
end

function Server:set_environment(name, value, options)
    return environment.run(servers[self], nil, "set", name, value, options)
end

function Server:unset_environment(name, options)
    return environment.run(servers[self], nil, "unset", name, nil, options)
end

function Server:remove_environment(name, options)
    return environment.run(servers[self], nil, "remove", name, nil, options)
end

function Server:snapshot(options)
    return capture(servers[self], options)
end

function Server:handle(snapshot, record)
    return entities.from_snapshot(servers[self], snapshot, record)
end

function Server:set_buffer(name, bytes, options)
    return buffer.run(servers[self], nil, "set", name, bytes, options)
end

function Server:show_buffer(name, options)
    return buffer.run(servers[self], nil, "show", name, nil, options)
end

function Server:delete_buffer(name, options)
    return buffer.run(servers[self], nil, "delete", name, nil, options)
end

function Server:detach_client(selector, options)
    return client.run(servers[self], "detach", selector, nil, options, entities.inspect)
end

function Server:switch_client(selector, session, options)
    return client.run(servers[self], "switch", selector, session, options, entities.inspect)
end

function Server:new_session(options)
    return domain.create(servers[self], nil, "session", options, entities.from_reference)
end

function Server:observe(session, options)
    return observation.open(servers[self], session, options)
end

function Server:query(options)
    return live_query.run(servers[self], options, false)
end

function Server:query_panes(options)
    return live_query.run(servers[self], options, false, "pane")
end

function Server:explain(options)
    return live_query.run(servers[self], options, true)
end

function Server:explain_panes(options)
    return live_query.run(servers[self], options, true, "pane")
end

local function execute(server, method, value, options)
    local state = servers[server]
    if state.closed then
        return state.runtime:_operation(function()
            return nil,
                errors.new("closed", "server handle is closed", {
                    operation = method,
                    effect = "not_sent",
                })
        end, { operation = method, effect = "not_sent" })
    end
    return execution[method](state.runtime, state.bound, value, options)
end

function Server:command(argv, options)
    return execute(self, "command", argv, options)
end

function Server:group(commands, options)
    return execute(self, "group", commands, options)
end

function Server:batch(commands, options)
    return execute(self, "batch", commands, options)
end

--- Close owned connections; the selected tmux daemon remains running.
function Server:close()
    local state = servers[self]
    state.closed = true
    return state.bound:close()
end

function M.connect(runtime, options)
    local copied, validation_error = connection_options(options)
    local binding
    local request = runtime:_operation(function(rt)
        if not copied then
            return nil, validation_error
        end
        binding = endpoints.bind(rt, copied)
        local bound, err = binding:await()
        if not bound then
            return nil, err
        end
        local evidence
        evidence, err = bound:evidence()
        if not evidence then
            bound:close():await()
            return nil, err
        end
        local state = { runtime = rt, bound = bound, version = evidence.version, methods = Server }
        local server = setmetatable({}, {
            __index = function(_, key)
                return state.methods[key]
            end,
            __metatable = "libtmux.Server",
        })
        state.capture = function(capture_spec)
            return capture(state, capture_spec)
        end
        state.prepare_capture = function(capture_spec)
            return capture_options(state, capture_spec)
        end
        state.capture_commands = function(capture_spec)
            return capture_commands(state, capture_spec)
        end
        servers[server] = state
        return server
    end, { operation = "connect", effect = "not_sent" })
    request:_on_retire(function()
        if not request:result() and binding then
            -- Cancellation can discard delivery after binding already succeeded.
            local bound = binding:result()
            if bound then
                bound:close()
            end
        end
    end)
    return request
end

-- Owned servers: a private daemon, its directory, and a stop that is confirmed.

local owned_servers = setmetatable({}, { __mode = "kv" })
local Owned = {}
local DEFAULT_TIMEOUT = 5000
local POLL_MILLISECONDS = 10
local DIRECTORY_TEMPLATE = "/libtmux-XXXXXX"
-- What tmux or libtmux would read to find another server, and the variable the
-- daemon gets in their place.
local DAEMON_SCRUBBED = {
    TMUX = true,
    TMUX_PANE = true,
    TMUX_TMPDIR = true,
    LIBTMUX_SOCKET = true,
    LIBTMUX_SOCKET_PATH = true,
    LIBTMUX_SOCKET_NAME = true,
}
local BSD_SYSTEMS =
    { Darwin = true, FreeBSD = true, OpenBSD = true, NetBSD = true, DragonFly = true }
-- A connection that ends in one of these found no listener.
local NO_LISTENER = { ECONNREFUSED = true, ENOENT = true, ENOTSOCK = true }

local function start_failure(code, message, details)
    details = details or {}
    details.operation, details.effect = "start_server", details.effect or "not_sent"
    return errors.new(code, message, details)
end

local function absolute_path(value)
    return type(value) == "string"
        and value:sub(1, 1) == "/"
        and #value <= 4096
        and not value:find("\000", 1, true)
end

local function environment_overlay(overlay)
    if overlay == nil then
        return {}
    end
    if not plain(overlay) then
        return nil, start_failure("invalid_options", "environment must map names to strings")
    end
    local copied = {}
    for name, value in next, overlay do
        if
            type(name) ~= "string"
            or not name:find("^[A-Za-z_][A-Za-z0-9_]*$")
            or type(value) ~= "string"
            or value:find("\000", 1, true)
        then
            return nil,
                start_failure(
                    "invalid_options",
                    "environment names are [A-Za-z_][A-Za-z0-9_]* and values are NUL-free strings"
                )
        end
        if DAEMON_SCRUBBED[name] then
            return nil, start_failure("invalid_options", "the daemon environment fixes " .. name)
        end
        copied[name] = value
    end
    return copied
end

local function start_options(options)
    if not plain(options) then
        return nil, start_failure("invalid_options", "start options must be a plain record")
    end
    local allowed =
        { binary = true, config = true, root = true, environment = true, timeout = true }
    for key in next, options do
        if not allowed[key] then
            return nil, start_failure("invalid_options", "unknown start option")
        end
    end
    if not absolute_path(options.binary) then
        return nil,
            start_failure("invalid_endpoint", "start needs an absolute tmux executable path")
    end
    for _, key in ipairs({ "config", "root" }) do
        if options[key] ~= nil and not absolute_path(options[key]) then
            return nil,
                start_failure("invalid_endpoint", key .. " must be an absolute, NUL-free path")
        end
    end
    if options.timeout ~= nil and not integer(options.timeout, 2147483647) then
        return nil,
            start_failure("invalid_options", "timeout must be a positive integer of milliseconds")
    end
    local overlay, err = environment_overlay(options.environment)
    if not overlay then
        return nil, err
    end
    return {
        binary = options.binary,
        config = options.config or "/dev/null",
        root = options.root and (options.root:gsub("/+$", "")),
        timeout = options.timeout or DEFAULT_TIMEOUT,
        environment = overlay,
    }
end

-- The most bytes a socket path may have: sun_path counts its terminating NUL
-- and is 108 bytes on Linux, 104 on macOS and the BSDs.
local function socket_path_limit(uv)
    local uname = uv and uv.os_uname and uv.os_uname()
    return (uname and BSD_SYSTEMS[uname.sysname] or not uname) and 103 or 107
end

local function choose_root(uv, requested)
    local limit = socket_path_limit(uv)
    local function needed(root)
        return #root + #DIRECTORY_TEMPLATE + endpoints.PIN_BYTES
    end
    local function fits(root)
        return needed(root) <= limit
    end
    if requested then
        if not fits(requested) then
            return nil,
                start_failure(
                    "invalid_endpoint",
                    (
                        "root leaves no room for a socket path: the longest path under it "
                        .. "has %d bytes, and the platform allows %d"
                    ):format(needed(requested), limit)
                )
        end
        return requested
    end
    local candidates = {}
    local temporary = uv and uv.os_tmpdir and uv.os_tmpdir()
    if type(temporary) == "string" and absolute_path(temporary) then
        candidates[1] = (temporary:gsub("/+$", ""))
    end
    candidates[#candidates + 1] = "/tmp"
    for _, root in ipairs(candidates) do
        if fits(root) then
            return root
        end
    end
    return nil,
        start_failure("invalid_endpoint", "no temporary directory leaves room for a socket path")
end

-- The caller's environment, less what selects another server, plus the overlay.
local function inherited_environment(uv, overlay)
    local entries = {}
    for name, value in pairs(uv.os_environ()) do
        if not DAEMON_SCRUBBED[name] and overlay[name] == nil then
            entries[#entries + 1] = name .. "=" .. value
        end
    end
    for name, value in pairs(overlay) do
        entries[#entries + 1] = name .. "=" .. value
    end
    table.sort(entries)
    return entries
end

-- Every socket under the directory but libtmux's own, relative to it.
local function foreign_sockets(uv, directory, own)
    local found = {}
    local function walk(prefix, depth)
        local listing = uv.fs_scandir(directory .. prefix)
        while listing do
            local name, kind = uv.fs_scandir_next(listing)
            if not name then
                break
            end
            local relative = prefix .. "/" .. name
            if kind == "unknown" then
                local stat = uv.fs_lstat(directory .. relative)
                kind = stat and stat.type
            end
            if kind == "socket" and relative:sub(2) ~= own then
                found[#found + 1] = relative:sub(2)
            elseif kind == "directory" and depth < 8 then
                walk(relative, depth + 1)
            end
        end
    end
    walk("", 0)
    table.sort(found)
    return found
end

-- Removes a directory tree the library made; a link is removed, never followed.
local function remove_tree(uv, path)
    local listing = uv.fs_scandir(path)
    while listing do
        local name, kind = uv.fs_scandir_next(listing)
        if not name then
            break
        end
        local child = path .. "/" .. name
        if kind == "unknown" then
            local stat = uv.fs_lstat(child)
            kind = stat and stat.type
        end
        local removed, err
        if kind == "directory" then
            removed, err = remove_tree(uv, child)
        else
            removed, err = uv.fs_unlink(child)
        end
        if not removed then
            return nil, err
        end
    end
    local removed, err = uv.fs_rmdir(path)
    if not removed and not tostring(err):find("^ENOENT") then
        return nil, err
    end
    return true
end

-- Connects to a socket once: "answers", "gone" or "unknown". Only a refusal or
-- a missing path proves nothing listens; any other failure proves nothing.
local function probe(uv, path, callback)
    local pipe, cause = uv.new_pipe(false)
    if not pipe then
        return callback("unknown", cause)
    end
    local finished = false
    local function finish(outcome, err)
        if finished then
            return
        end
        finished = true
        pipe:close()
        callback(outcome, err)
    end
    local ok, started, message = pcall(pipe.connect, pipe, path, function(err)
        if err == nil then
            finish("answers")
        elseif NO_LISTENER[tostring(err):match("^(%u+)")] then
            finish("gone", err)
        else
            finish("unknown", err)
        end
    end)
    if not ok or not started then
        finish("unknown", ok and message or started)
    end
end

-- Runs `tmux -S path -N kill-server` and reports when the client has exited,
-- killing a client that outlasts the timeout. -N keeps a missing daemon missing.
local function run_kill_server(state, path, callback)
    local done, handle, cancel = false, nil, nil
    local function finish(err)
        if done then
            return
        end
        done = true
        if cancel then
            pcall(cancel)
        end
        if handle and not handle:is_closing() then
            handle:close()
        end
        callback(err)
    end
    local ok, spawned, message = pcall(state.uv.spawn, state.binary, {
        args = { "-S", path, "-N", "kill-server" },
        env = state.env,
    }, function()
        finish(nil)
    end)
    if not ok or not spawned then
        return finish(ok and message or spawned)
    end
    handle = spawned
    local timed, canceller = pcall(state.driver.timer, state.timeout, function()
        if not done then
            pcall(handle.kill, handle, "sigkill")
        end
    end)
    cancel = timed and canceller or nil
end

-- Stops the daemon on a socket and polls until nothing listens, or the timeout
-- passes. callback(true) when it is gone, else callback(false, cause).
local function terminate(state, path, callback)
    local open, gone, cause = 2, false, nil
    local function join()
        open = open - 1
        if open == 0 then
            callback(gone, not gone and cause or nil)
        end
    end
    run_kill_server(state, path, function(err)
        cause = cause or err
        join()
    end)
    local deadline = state.driver.now() + state.timeout
    local function poll()
        probe(state.uv, path, function(outcome, err)
            if outcome == "gone" then
                gone = true
                return join()
            end
            cause = err or cause
            if state.driver.now() >= deadline then
                return join()
            end
            local ok = pcall(state.driver.timer, POLL_MILLISECONDS, poll)
            if not ok then
                join()
            end
        end)
    end
    poll()
end

local function stop_failed(state, cause, message)
    return errors.new(
        "stop_failed",
        message or ("tmux still answers on its private socket; kept " .. state.directory),
        {
            operation = "stop_server",
            effect = "unknown",
            directory = state.directory,
            cause = cause,
        }
    )
end

local function finish_stop(state, err)
    state.stopping = false
    if err == nil or err.code == "leaked_server" then
        state.done, state.final = true, err
    end
    local waiters = state.waiters
    state.waiters = {}
    for _, waiter in ipairs(waiters) do
        local ok, cause = pcall(waiter, err)
        if not ok then
            state.runtime:_record(errors.wrap(cause, "cleanup_failed"))
        end
    end
    -- A finished server needs no cleanup when the runtime ends.
    if state.done and state.lease then
        state.lease:close()
    end
end

-- The one stop. It runs on the driver alone, never through a runtime request,
-- because the runtime refuses new requests once it is closing, which is when
-- cleanup of a server nobody stopped runs. Waiters hear the same outcome:
-- nil for a stopped server, `leaked_server` for a stopped one that left another
-- behind, and `stop_failed` for one that still answers, which a later call
-- tries again.
local function stop(state, callback)
    if state.done then
        return callback(state.final)
    end
    state.waiters[#state.waiters + 1] = callback
    if state.stopping then
        return
    end
    state.stopping = true
    local function finish(err)
        finish_stop(state, err)
    end
    local leaked, stuck = {}, {}
    local function remove()
        if #stuck > 0 then
            return finish(stop_failed(state, state.cause))
        end
        local removed, err = remove_tree(state.uv, state.directory)
        if not removed then
            return finish(
                stop_failed(state, err, "cannot remove the private directory " .. state.directory)
            )
        end
        if #leaked > 0 then
            return finish(
                errors.new(
                    "leaked_server",
                    "stopped, but the program left tmux servers under the run directory: "
                        .. table.concat(leaked, ", "),
                    { operation = "stop_server", effect = "completed", sockets = leaked }
                )
            )
        end
        finish(nil)
    end
    local function check(sockets, index)
        local relative = sockets[index]
        if not relative then
            return remove()
        end
        local path = state.directory .. "/" .. relative
        probe(state.uv, path, function(outcome)
            if outcome == "gone" then
                return check(sockets, index + 1)
            end
            leaked[#leaked + 1] = relative
            terminate(state, path, function(gone, cause)
                if not gone then
                    stuck[#stuck + 1], state.cause = relative, cause
                end
                check(sockets, index + 1)
            end)
        end)
    end
    local function after_daemon(gone, cause)
        if not gone then
            return finish(stop_failed(state, cause))
        end
        check(foreign_sockets(state.uv, state.directory, "tmux.sock"), 1)
    end
    local function stop_daemon()
        terminate(state, state.socket, after_daemon)
    end
    -- The handle's socket alias lives in the directory, so it goes first.
    local server = state.server
    if not server or state.handle_closed then
        return stop_daemon()
    end
    state.handle_closed = true
    local ok, closing = pcall(server.close, server)
    if not ok or not closing then
        return stop_daemon()
    end
    if not pcall(closing._on_retire, closing, stop_daemon) then
        stop_daemon()
    end
end

local function stop_request(state)
    return state.runtime:_logical_request({
        operation = "stop_server",
        effect = "unknown",
        start = function(settle, retire)
            local waiting = true
            stop(state, function(err)
                if not waiting then
                    return
                end
                waiting = false
                if err ~= nil and err == state.final then
                    state.final_reported = true
                end
                settle(err == nil and true or nil, err)
                retire()
            end)
            -- Cancelling the wait leaves the stop running; the runtime still owns it.
            return function()
                if waiting then
                    waiting = false
                    retire()
                end
            end
        end,
    })
end

-- A request the calling scope owns until released. Cancelling the scope runs
-- the stop, and the scope cannot retire before that stop finishes. The request
-- settles as soon as it starts: an abort still reaches a settled request that
-- has not retired, but one that never started retires without a hook, so
-- `ready` waits for the start before the scope does anything that can fail.
local function scope_guard(state)
    local guard = { released = false }
    guard.request = state.runtime:_logical_request({
        operation = "stop_server",
        effect = "unknown",
        start = function(settle, retire)
            guard.retire = retire
            settle(true)
            if guard.released then
                retire()
            end
            return function()
                stop(state, function()
                    retire()
                end)
            end
        end,
    })
    function guard.ready()
        guard.request:await()
    end
    function guard.release()
        guard.released = true
        if guard.retire then
            guard.retire()
        end
    end
    return guard
end

---@param options libtmux.StartServerOptions
---@return libtmux.Request<libtmux.OwnedServer>
function M.start(runtime, options)
    local copied, validation_error = start_options(options)
    return runtime:_operation(function(rt, operation)
        if not copied then
            return nil, validation_error
        end
        local uv = rt._driver.uv
        local root, err = choose_root(uv, copied.root)
        if not root then
            return nil, err
        end
        if not (uv and uv.fs_mkdtemp and uv.os_environ and uv.spawn and uv.new_pipe) then
            return nil,
                start_failure(
                    "unsupported",
                    "start_server needs a driver with filesystem and process support"
                )
        end
        local env = inherited_environment(uv, copied.environment)
        local directory, cause = uv.fs_mkdtemp(root .. DIRECTORY_TEMPLATE)
        if not directory then
            return nil,
                start_failure(
                    "filesystem_error",
                    "cannot create the private directory",
                    { cause = cause }
                )
        end
        env[#env + 1] = "TMUX_TMPDIR=" .. directory
        local state = {
            runtime = rt,
            uv = uv,
            driver = rt._driver,
            binary = copied.binary,
            config = copied.config,
            timeout = copied.timeout,
            directory = directory,
            socket = directory .. "/tmux.sock",
            env = env,
            waiters = {},
        }
        state.lease, err = rt:_resource(function(done)
            stop(state, function(stopped)
                if stopped ~= nil and stopped == state.final and state.final_reported then
                    stopped = nil
                end
                done(stopped)
            end)
        end)
        if not state.lease then
            remove_tree(uv, directory)
            return nil, err
        end
        local guard = scope_guard(state)
        guard.ready()
        local function fail(reason)
            state.final_reported = true
            stop_request(state):await()
            guard.release()
            return nil, reason
        end
        operation:_set_effect("unknown")
        local started, started_error = command
            .group(rt, { binary = state.binary, socket = state.socket, config = state.config }, {
                { "start-server" },
                { "set-option", "-s", "exit-empty", "off" },
            }, { timeout = state.timeout, env = state.env })
            :await()
        if not started then
            return fail(start_failure("start_failed", "tmux did not start a server", {
                effect = started_error.effect,
                cause = started_error,
            }))
        end
        local server, connect_error = M.connect(rt, {
            binary = state.binary,
            socket_path = state.socket,
            config_path = state.config,
        }):await()
        if not server then
            return fail(connect_error)
        end
        state.server = server
        guard.release()
        local owned = setmetatable({ server = server, socket_path = state.socket }, {
            __index = Owned,
            __metatable = "libtmux.OwnedServer",
        })
        owned_servers[owned] = state
        return owned
    end, { operation = "start_server", effect = "not_sent" })
end

---@param options libtmux.StartServerOptions
---@param body fun(server:libtmux.Server, owned:libtmux.OwnedServer):unknown?, libtmux.Error?
---@return libtmux.Request<unknown>
function M.scoped(runtime, options, body)
    return runtime:_operation(function(rt)
        if type(body) ~= "function" then
            return nil, start_failure("invalid_callback", "with_server needs a body function")
        end
        local owned, err = M.start(rt, options):await()
        if not owned then
            return nil, err
        end
        local guard = scope_guard(owned_servers[owned])
        guard.ready()
        -- The body runs in this task, so it may await. A raised error cancels the
        -- task, and the guard stops the server on the way out.
        local value, body_error = body(owned.server, owned)
        local _, stop_error = owned:stop():await()
        guard.release()
        if body_error ~= nil then
            return nil, body_error
        end
        if stop_error then
            return nil, stop_error
        end
        return value
    end, { operation = "with_server", effect = "not_sent" })
end

function Owned:stop()
    return stop_request(assert(owned_servers[self], "invalid owned server"))
end

--- Options for `libtmux.Runtime:start_server`.
---
--- `binary` is the only required field. The server lives in a fresh directory
--- under `root`, with its socket inside, so `root` plus about 45 bytes must fit
--- a socket path (`sun_path`: 107 bytes on Linux, 103 on macOS and the BSDs);
--- a longer root fails with `invalid_endpoint` before anything is created. The
--- directory holds the daemon's `TMUX_TMPDIR`, so a tmux client that names no
--- socket cannot reach another server from inside it.
---
--- The daemon inherits the caller's environment less `TMUX`, `TMUX_PANE` and
--- every `LIBTMUX_SOCKET*` variable, plus `environment`. `environment` cannot
--- set those names or `TMUX_TMPDIR`. The daemon runs with `exit-empty off`, so
--- it stays up with no session.
---@class libtmux.StartServerOptions
---@field binary string Absolute tmux executable path.
--- Absolute configuration path. Defaults to `/dev/null`, which loads none.
---@field config? string
--- Absolute directory that holds the private one. Defaults to the system
--- temporary directory, or `/tmp` when that is too long for a socket path.
---@field root? string
--- Variables for the daemon and its panes, over the caller's.
---@field environment? table<string, string>
--- Milliseconds that starting and stopping each wait for tmux. Defaults to 5000.
---@field timeout? integer

--- A tmux server that `libtmux.Runtime:start_server` started and owns.
---
--- `server` is a `libtmux.Server` for it, the same handle `libtmux.Runtime:connect`
--- returns, and `socket_path` is its socket, for a second handle. `stop` ends
--- the daemon and removes its directory. The runtime stops every owned server
--- that is still running when it ends, whether the body returned, failed or was
--- cancelled, so a program that forgets `stop` leaves nothing behind. A stop
--- the runtime ran for you that finds a `leaked_server` or `stop_failed` fails
--- the run with `cleanup_failed`.
---
--- `libtmux.Server:close` on `server` still only releases the handle.
---@class libtmux.OwnedServer
---@field server libtmux.Server
---@field socket_path string The private socket.
--- Runs `kill-server`, then connects to the socket until nothing listens, for
--- at most `timeout` milliseconds, and removes the directory. It resolves to
--- `true` once the daemon is gone and the directory removed, and again on later
--- calls. A daemon that still answers fails with `stop_failed`, keeps the
--- directory and names it in `directory`; calling again tries once more. When
--- the program left another tmux server under the directory, `stop` stops it
--- too and fails with `leaked_server`, naming each socket in `sockets`.
---@field stop fun(self:libtmux.OwnedServer):libtmux.Request<boolean>

--- Options for `libtmux.Runtime:connect`.
---
--- Name the server with `socket_path`, or leave it out and let the environment
--- or tmux choose. With no `socket_path`, `LIBTMUX_SOCKET_PATH` names a socket
--- path (tmux `-S`), else `LIBTMUX_SOCKET` names a socket (`-L`), and with
--- neither set tmux gets no socket and picks the server itself: the one in
--- `TMUX` inside tmux, otherwise its default socket. A `socket_path` option
--- comes first and leaves both variables unread. A variable that is empty or
--- only whitespace counts as unset, and `LIBTMUX_SOCKET_PATH` must be an
--- absolute path.
---
--- The connection never starts a daemon. A connection that names no socket, or
--- names one with `LIBTMUX_SOCKET`, fails with `invalid_endpoint` when tmux
--- finds none running. A socket path, from the option or `LIBTMUX_SOCKET_PATH`,
--- fails with `invalid_endpoint` when no file is there, and with
--- `uncertain_generation` when the file outlived its server.
---
--- A socket path is pinned: commands go through a private link to the socket,
--- so a replaced socket stops the handle. Every command also checks the
--- daemon's pid, start time and release. A socket name or tmux's own choice has
--- no path to pin, so that check is the only identity there.
---@class libtmux.ConnectOptions
---@field binary string Absolute tmux executable path.
---@field socket_path? string Absolute existing daemon socket path.
---@field config_path? string Absolute configuration path.

---@class libtmux.SnapshotOptions
---@field strict? boolean Perform one additional topology verification pass.
---@field fields? table<string, string[]> Collection names mapped to requested catalog fields.
---@field max_rows? integer
---@field max_bytes? integer
---@field timeout? integer Listing command timeout in milliseconds.

---@class libtmux.CommandOptions
---@field stdin? string
---@field cwd? string
---@field env? string[] Explicit process environment entries.
---@field timeout? number
---@field deadline? number
---@field max_output_bytes? integer
---@field drain_timeout? integer
---@field kill_timeout? integer

---@class libtmux.CommandResult
---@field stdout string
---@field stderr string
---@field exit_code integer
---@field signal integer

---@class libtmux.CommandBatchOptions
---@field concurrency? integer
---@field process? libtmux.CommandOptions

---@class libtmux.CommandOutcome
---@field status "completed"|"failed"|"unknown"|"skipped"
---@field effect "not_sent"|"unknown"|"completed"
---@field value? libtmux.CommandResult
---@field error? libtmux.Error

--- A handle to one running tmux server, reached through a connected runtime.
---
--- `libtmux.Runtime:connect` resolves to a server for a daemon that is already
--- running; it never starts one, and closing the handle leaves the daemon
--- running. `libtmux.Runtime:start_server` starts a private daemon and owns it
--- (see `libtmux.OwnedServer`). With no socket named, `connect` passes tmux
--- none, and tmux picks the server (see `libtmux.ConnectOptions`). A method that talks to tmux
--- returns a `libtmux.Request`: call `libtmux.Request:await` from a task the
--- runtime manages, or pass a callback to `libtmux.Request:on_complete`. A
--- failed request reports a `libtmux.Error`. If the daemon restarts or its
--- socket is replaced, the handle stops working and the caller connects again.
---
--- # What is on here
---
--- A tmux server does a great many things, so this class has a great many
--- methods. They fall into a few groups:
---
--- **Connecting.** `libtmux.Runtime:connect` takes `libtmux.ConnectOptions`: an
--- absolute path to the tmux binary and, optionally, to the daemon's socket.
--- `Server:close` closes the connections the handle owns. `Server:observe`
--- takes a session handle and resolves to a `libtmux.Observation`, a
--- control-mode view of that session whose watches report pane output,
--- notifications and format values.
---
--- `libtmux.Runtime:connect`, `Server:close` and `Server:observe`
---
--- **Checking feature support.** `Server:capabilities` reads the connected
--- daemon again and resolves to a detached `libtmux.CapabilityReport`: named
--- feature requirements and decisions, plus release-specific workarounds.
--- Editing the report does not change command admission.
---
--- `Server:capabilities`, `libtmux.CapabilityReport.features` and
--- `libtmux.CapabilityReport.workarounds`
---
--- **Finding one thing.** Take one record from a `libtmux.Snapshot`, or from
--- the rows of a query, with `libtmux.Selection:one`, which reports no match or
--- several as errors, or `libtmux.Selection:one_or_nil`, which also accepts no
--- match. Pass it, with its snapshot, to `Server:handle`: that binds the record
--- to a live session, window, window link, pane, client or buffer handle of the
--- same class, and returns it directly rather than as a request.
---
--- `libtmux.Selection:one`, `libtmux.Selection:one_or_nil` and `Server:handle`
---
--- **Listing everything.** `Server:snapshot` lists sessions, windows, window
--- links, panes, clients and buffers, and resolves to a `libtmux.Snapshot`
--- whose collections are selections. The capture spans several tmux commands,
--- so it is not an atomic view: observed races land in `libtmux.Snapshot.races`
--- and clear `libtmux.Snapshot.complete`, and `libtmux.SnapshotOptions.strict`
--- adds a verification pass.
---
--- `Server:snapshot`, `libtmux.Snapshot.races`, `libtmux.Snapshot.complete` and
--- `libtmux.SnapshotOptions.strict`
---
--- **Querying things and getting around.** `Server:query` reads live state and
--- resolves to the rows that match a criteria table, with the snapshot and plan
--- behind them; `Server:query_panes` does the same for panes. `Server:explain`
--- and `Server:explain_panes` return the plan without contacting tmux. On a
--- snapshot already in hand, `libtmux.Selection:where` and
--- `libtmux.Selection:filter` narrow a collection in memory, and
--- `libtmux.Selection:first`, `libtmux.Selection:count` and
--- `libtmux.Selection:exists` inspect it; the `libtmux.query` module does the
--- same for ordinary Lua tables. Records lead to each other without another
--- command: `libtmux.SnapshotSession.window_links`,
--- `libtmux.SnapshotWindow.panes`, `libtmux.SnapshotPane.window`,
--- `libtmux.SnapshotWindowLink.session` and
--- `libtmux.SnapshotWindowLink.window`.
---
--- `Server:query`, `Server:query_panes`, `Server:explain`,
--- `Server:explain_panes`, `libtmux.Selection:where`,
--- `libtmux.Selection:filter`, `libtmux.Selection:first`,
--- `libtmux.Selection:count`, `libtmux.Selection:exists`, `libtmux.query`,
--- `libtmux.SnapshotSession.window_links`, `libtmux.SnapshotWindow.panes`,
--- `libtmux.SnapshotPane.window`, `libtmux.SnapshotWindowLink.session` and
--- `libtmux.SnapshotWindowLink.window`
---
--- **Changing things.** `Server:new_session` creates a detached session and
--- resolves to a `libtmux.Creation` holding handles for the session and the
--- window, pane and window link it starts with. `Server:switch_client` points
--- an attached client, selected by the name and TTY a snapshot reports, at a
--- session handle, and `Server:detach_client` detaches it.
---
--- `Server:new_session`, `Server:switch_client` and `Server:detach_client`
---
--- **Options and hooks.** `Server:get_option`, `Server:list_options`,
--- `Server:set_option` and `Server:unset_option` address the server's own
--- options; pass `scope = "global_session"` or `"global_window"` for tmux's
--- global defaults. `Server:get_hook`, `Server:list_hooks`, `Server:set_hook`
--- and `Server:unset_hook` need one of those two scopes spelled out. The global
--- environment has `Server:get_environment`, `Server:list_environment` and
--- `Server:set_environment`; `Server:unset_environment` deletes a name, while
--- `Server:remove_environment` records a removal marker instead.
---
--- `Server:get_option`, `Server:list_options`, `Server:set_option`,
--- `Server:unset_option`, `Server:get_hook`, `Server:list_hooks`,
--- `Server:set_hook`, `Server:unset_hook`, `Server:get_environment`,
--- `Server:list_environment`, `Server:set_environment`,
--- `Server:unset_environment` and `Server:remove_environment`
---
--- **Everything else tmux keeps.** Paste buffers, always by explicit name:
--- `Server:set_buffer` stores bytes, `Server:show_buffer` reads them back and
--- `Server:delete_buffer` removes the buffer. None infers the most recent
--- buffer. Key bindings, configuration files, shell jobs and wait-for channels
--- have no method here; reach them through `Server:command`.
---
--- `Server:set_buffer`, `Server:show_buffer`, `Server:delete_buffer` and
--- `Server:command`
---
--- **Things that need a terminal.** None. The luv and Neovim adapters do not
--- own an interactive terminal, so `libtmux.Session:attach` returns
--- `unsupported_tty`.
---
--- `libtmux.Session:attach`
---
--- **Running a command.** Anything tmux can do that is not here is reachable
--- through `Server:command`, which runs one tmux command from literal arguments
--- and resolves to its stdout, stderr, exit code and signal; a nonzero exit is
--- reported in that result, not as a failure. `Server:group` sends several
--- commands as one ordered group with a single aggregate result, and
--- `Server:batch` runs independent commands and reports an outcome for each.
---
--- `Server:command`, `Server:group` and `Server:batch`
---@class libtmux.Server
---@field capabilities fun(self:libtmux.Server):libtmux.Request<libtmux.CapabilityReport>
---@field get_option fun(self:libtmux.Server,name:string,options?:libtmux.SettingGetOptions):
--- libtmux.Request<libtmux.OptionRecord>
---@field list_options fun(self:libtmux.Server,options?:libtmux.SettingListOptions):
--- libtmux.Request<libtmux.OptionRecord[]>
---@field set_option fun(self:libtmux.Server,name:string,value:libtmux.OptionInput,
--- options?:libtmux.SettingSetOptions):
--- libtmux.Request<boolean>
---@field unset_option fun(self:libtmux.Server,name:string,options?:libtmux.SettingUnsetOptions):
--- libtmux.Request<boolean>
---@field get_hook fun(self:libtmux.Server,name:string,options?:libtmux.SettingGetOptions):
--- libtmux.Request<libtmux.HookRecord>
---@field list_hooks fun(self:libtmux.Server,options?:libtmux.SettingListOptions):
--- libtmux.Request<libtmux.HookRecord[]>
---@field set_hook fun(self:libtmux.Server,name:string,value:libtmux.HookProgram,
--- options?:libtmux.SettingSetOptions):
--- libtmux.Request<boolean>
---@field unset_hook fun(self:libtmux.Server,name:string,options?:libtmux.SettingUnsetOptions):
--- libtmux.Request<boolean>
---@field get_environment fun(self:libtmux.Server,name:string,
--- options?:libtmux.EnvironmentGetOptions):
--- libtmux.Request<libtmux.EnvironmentRecord>
---@field list_environment fun(self:libtmux.Server,options?:libtmux.EnvironmentListOptions):
--- libtmux.Request<libtmux.EnvironmentRecord[]>
---@field set_environment fun(self:libtmux.Server,name:string,value:string,
--- options?:libtmux.EnvironmentSetOptions):
--- libtmux.Request<boolean>
---@field unset_environment fun(self:libtmux.Server,name:string,
--- options?:libtmux.EnvironmentOptions):
--- libtmux.Request<boolean>
---@field remove_environment fun(self:libtmux.Server,name:string,
--- options?:libtmux.EnvironmentOptions):
--- libtmux.Request<boolean>
---@field observe fun(self:libtmux.Server,session:libtmux.Session,
--- options?:libtmux.ObservationOptions):libtmux.Request<libtmux.Observation>
---@field query fun(self:libtmux.Server,options?:libtmux.LiveQueryOptions):
--- libtmux.Request<libtmux.LiveQueryResult<table>>
---@field query_panes fun(self:libtmux.Server,options?:libtmux.LiveQueryOptions):
--- libtmux.Request<libtmux.LiveQueryResult<libtmux.SnapshotPane>>
---@field explain fun(self:libtmux.Server,options?:libtmux.LiveQueryOptions):
--- libtmux.Request<libtmux.LiveQueryPlan>
---@field explain_panes fun(self:libtmux.Server,options?:libtmux.LiveQueryOptions):
--- libtmux.Request<libtmux.LiveQueryPlan>
---@field new_session fun(self:libtmux.Server,options?:libtmux.NewSessionOptions):
--- libtmux.Request<libtmux.Creation>
---@field set_buffer fun(self:libtmux.Server,name:string,bytes:string,
--- options?:libtmux.BufferOptions):
--- libtmux.Request<boolean>
---@field show_buffer fun(self:libtmux.Server,name:string,options?:libtmux.BufferOptions):
--- libtmux.Request<libtmux.BufferValue>
---@field delete_buffer fun(self:libtmux.Server,name:string,options?:libtmux.BufferOptions):
--- libtmux.Request<boolean>
---@field detach_client fun(self:libtmux.Server,selector:libtmux.ClientSelector,
--- options?:libtmux.ClientOptions):libtmux.Request<boolean>
---@field switch_client fun(self:libtmux.Server,selector:libtmux.ClientSelector,
--- session:libtmux.Session,options?:libtmux.SwitchClientOptions):
--- libtmux.Request<boolean>
--- Binds a snapshot record to a live handle of its class.
---@field handle (fun(self:libtmux.Server,snapshot:libtmux.Snapshot,
--- record:libtmux.SnapshotSession):libtmux.Session?,libtmux.Error?)|(fun(
--- self:libtmux.Server,snapshot:libtmux.Snapshot,
--- record:libtmux.SnapshotWindow):libtmux.Window?,libtmux.Error?)|(fun(
--- self:libtmux.Server,snapshot:libtmux.Snapshot,
--- record:libtmux.SnapshotWindowLink):libtmux.WindowLink?,libtmux.Error?)|(fun(
--- self:libtmux.Server,snapshot:libtmux.Snapshot,
--- record:libtmux.SnapshotPane):libtmux.Pane?,libtmux.Error?)|(fun(
--- self:libtmux.Server,snapshot:libtmux.Snapshot,
--- record:libtmux.SnapshotClient):libtmux.Client?,libtmux.Error?)|(fun(
--- self:libtmux.Server,snapshot:libtmux.Snapshot,
--- record:libtmux.SnapshotBuffer):libtmux.Buffer?,libtmux.Error?)
---@field command fun(self:libtmux.Server, argv:string[],
--- options?:libtmux.CommandOptions):libtmux.Request<libtmux.CommandResult>
---@field group fun(self:libtmux.Server, commands:string[][],
--- options?:libtmux.CommandOptions):libtmux.Request<libtmux.CommandResult>
---@field batch fun(self:libtmux.Server, commands:string[][],
--- options?:libtmux.CommandBatchOptions):libtmux.Request<libtmux.CommandOutcome[]>
---@field snapshot fun(self:libtmux.Server,
--- options?:libtmux.SnapshotOptions):libtmux.Request<libtmux.Snapshot>
---@field close fun(self:libtmux.Server):libtmux.Request<boolean>

---@class libtmux.SnapshotSession: libtmux.Fields.Session
---@field id string
---@field name string
---@field ref table
---@field window_links libtmux.SnapshotWindowLink[]

---@class libtmux.SnapshotWindow: libtmux.Fields.Window
---@field id string
---@field ref table
---@field panes libtmux.SnapshotPane[]
---@field window_links libtmux.SnapshotWindowLink[]

---@class libtmux.SnapshotPane: libtmux.Fields.Pane
---@field id string
---@field window_id string
---@field index integer
---@field ref table
---@field window? libtmux.SnapshotWindow Missing when captured relationships are inconsistent.

---@class libtmux.SnapshotWindowLink: libtmux.Fields.WindowLink
---@field session_id string
---@field window_id string
---@field index integer
---@field ref table
---@field session? libtmux.SnapshotSession
---@field window? libtmux.SnapshotWindow

---@class libtmux.SnapshotClient: libtmux.Fields.Client
---@field name string
---@field tty string
---@field session_name string|libtmux.Null
---@field ref table
---@field session? libtmux.SnapshotSession|libtmux.Null

---@class libtmux.SnapshotBuffer: libtmux.Fields.Buffer
---@field name string
---@field ref table

---@class libtmux.Snapshot
---@field sessions libtmux.Selection<libtmux.SnapshotSession>
---@field windows libtmux.Selection<libtmux.SnapshotWindow>
---@field panes libtmux.Selection<libtmux.SnapshotPane>
---@field window_links libtmux.Selection<libtmux.SnapshotWindowLink>
---@field clients libtmux.Selection<libtmux.SnapshotClient>
---@field buffers libtmux.Selection<libtmux.SnapshotBuffer>
---@field raw table<string, libtmux.Selection<table>>
---@field complete boolean
---@field races table[]
---@field acquisition {started:number, finished:number}
---@field projections table<string, string[]>
---@field requested_projections table<string, string[]>
---@field capabilities {version:string, fields:table<string, table<string, boolean>>}
---@field verification {passes:integer, consistent:boolean?}

return M
