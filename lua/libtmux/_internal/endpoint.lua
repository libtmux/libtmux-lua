local command = require("libtmux._internal.command")
local errors = require("libtmux._internal.error")
local fields = require("libtmux._internal.fields")
local identity = require("libtmux._internal.identity")
local metadata = require("libtmux._internal.metadata")
local process = require("libtmux._internal.process")
local unpack_values = rawget(table, "unpack") or unpack
local M, Bound = {}, {}
local bindings = setmetatable({}, { __mode = "kv" })
local projection = assert(metadata.projection("server", "3.2a", {
    "pid",
    "start_time",
    "version",
    "socket_path",
}))

local function failure(code, message, cause)
    return errors.new(code, message, { operation = "endpoint", effect = "not_sent", cause = cause })
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function absolute(value)
    return type(value) == "string"
        and value:sub(1, 1) == "/"
        and #value <= 4096
        and not value:find("\000", 1, true)
end

local function options_copy(options)
    if not plain(options) then
        return nil, failure("invalid_endpoint", "endpoint options must be a plain table")
    end
    local copied = {}
    for key, value in next, options do
        if key ~= "binary" and key ~= "socket" and key ~= "config" then
            return nil, failure("invalid_endpoint", "unknown endpoint option")
        end
        if not absolute(value) then
            return nil, failure("invalid_endpoint", "endpoint paths must be absolute and NUL-free")
        end
        copied[key] = value
    end
    if not copied.binary or not copied.socket or copied.socket:sub(-1) == "/" then
        return nil,
            failure("invalid_endpoint", "endpoint needs explicit executable and socket paths")
    end
    return copied
end

local function invalidate(state, reason)
    state.invalid = true
    if state.generation then
        identity.invalidate(state.generation, reason)
    end
    for lease in pairs(state.clients or {}) do
        lease:close()
    end
end

local function native(uv, method, args, callback)
    local called = false
    args[#args + 1] = function(err, value)
        if not called then
            called = true
            callback(err, value)
        end
    end
    local ok, result, err = pcall(function()
        return uv[method](unpack_values(args))
    end)
    if not called and (not ok or not result) then
        called = true
        callback(ok and err or result)
    end
end

local cleanup
local function fs(state, method, args, allocated)
    return state.runtime:_request({
        bytes = 0,
        effect = "not_sent",
        operation = "endpoint",
        start = function(settle, retire)
            state.pending = state.pending + 1
            native(state.uv, method, args, function(err, value)
                if not err and allocated then
                    allocated(value)
                end
                if err then
                    settle(
                        nil,
                        failure("filesystem_error", "endpoint filesystem operation failed", err)
                    )
                else
                    settle(value == nil and true or value)
                end
                state.pending = state.pending - 1
                retire()
                cleanup(state)
            end)
            -- A cancelled filesystem waiter still owns its late allocation callback.
            return function() end
        end,
    })
end

cleanup = function(state)
    if not state.closing or state.cleaning then
        return
    end
    for lease in pairs(state.clients or {}) do
        lease:close()
    end
    if state.active > 0 or state.pending > 0 or (state.client_count or 0) > 0 then
        return
    end
    state.cleaning = true
    local first_error
    local function checked(err)
        if err and not tostring(err):match("^ENOENT") and not first_error then
            first_error = failure("cleanup_failed", "endpoint pin cleanup failed", err)
        end
    end
    local function directory()
        if not state.directory then
            state.done(first_error)
            return
        end
        native(state.uv, "fs_rmdir", { state.directory }, function(err)
            checked(err)
            state.done(first_error)
        end)
    end
    if state.alias then
        native(state.uv, "fs_unlink", { state.alias }, function(err)
            checked(err)
            directory()
        end)
    else
        directory()
    end
end

local function same_socket(stat, expected)
    return stat and stat.type == "socket" and stat.dev == expected.dev and stat.ino == expected.ino
end

local function precise_integer(value)
    return type(value) == "number" and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

local function verify(state)
    if state.invalid then
        return nil, failure("stale_generation", "endpoint generation is no longer current")
    end
    for _, path in ipairs({ state.options.socket, state.alias }) do
        local stat, err = fs(state, "fs_lstat", { path }):await()
        if not same_socket(stat, state.stat) then
            invalidate(state, "socket identity changed or became uncertain")
            return nil,
                failure(
                    "stale_generation",
                    "endpoint socket identity changed or became uncertain",
                    err
                )
        end
    end
    if state.invalid then
        return nil, failure("stale_generation", "endpoint closed during socket verification")
    end
    return true
end

local function read_evidence(state, operation)
    local result, err = command
        .execute(state.runtime, state.endpoint, {
            "display-message",
            "-p",
            assert(metadata.format(projection)),
        }, { timeout = 750, max_output_bytes = 16384 })
        :await()
    if not result then
        local _, retained_error = process.retain_output(operation, nil, err, "endpoint")
        return nil,
            failure("uncertain_generation", "cannot read pinned daemon evidence", retained_error)
    end
    local rows
    rows, err = metadata.decode(result.stdout, projection, { max_rows = 1, max_bytes = 16384 })
    if not rows or #rows ~= 1 or rows[1].pid <= 0 or rows[1].start_time < 0 then
        return nil, failure("uncertain_generation", "pinned daemon evidence is malformed", err)
    end
    local row = rows[1]
    local schema
    schema, err = fields.schema("server", row.version)
    if not schema then
        return nil, failure("unsupported_version", "pinned daemon version is unsupported", err)
    end
    return {
        pid = string.format("%.0f", row.pid),
        started = string.format("%.0f", row.start_time),
        version = row.version,
        socket = row.socket_path,
    }
end

local function preflight(state, operation)
    local valid, err = verify(state)
    if not valid then
        return nil, err
    end
    local observed
    observed, err = read_evidence(state, operation)
    local matched = observed ~= nil
    for key, value in pairs(state.evidence) do
        if not observed or observed[key] ~= value then
            matched = false
        end
    end
    if not matched then
        invalidate(state, "daemon evidence changed or became uncertain")
        return nil,
            failure("stale_generation", "pinned daemon evidence changed or became uncertain", err)
    end
    return verify(state)
end

function Bound:evidence()
    local state = bindings[self]
    if not state or state.invalid or not state.generation then
        return nil, failure("stale_generation", "endpoint generation is no longer current")
    end
    return identity.evidence(state.generation)
end

function Bound:generation()
    local evidence, err = self:evidence()
    if not evidence then
        return nil, err
    end
    return bindings[self].generation
end

function Bound:close()
    local state = assert(bindings[self], "invalid endpoint")
    invalidate(state, "endpoint closed")
    return state.lease:close()
end

local function execute(state, commands, options, raw_result)
    local prepared, preparation_error = command.prepare(state.endpoint, commands)
    local plan
    if not preparation_error then
        plan, preparation_error = process.prepare(prepared, options)
    end
    state.active = state.active + 1
    local request = state.runtime:_operation(function(rt, operation)
        if preparation_error then
            return nil, preparation_error
        end
        assert(plan)
        local valid, err = preflight(state, operation)
        if not valid then
            return nil, err
        end
        operation:_set_effect("unknown")
        local result
        result, err = process.execute(rt, plan.argv, plan.options):await()
        result, err = process.retain_output(operation, result, err, "endpoint")
        if raw_result and err and err.code == "exit_failed" and err.effect == "completed" then
            return err.partial
        end
        return result, err
    end, { operation = "endpoint", effect = "not_sent" })
    request:_on_retire(function()
        state.active = state.active - 1
        cleanup(state)
    end)
    if plan and not request:is_settled() then
        local retained, cause = request:_retain(plan.bytes)
        if not retained then
            request:cancel(failure("queue_full", "endpoint input byte limit reached", cause))
        end
    end
    return request
end

function Bound:execute(argv, options)
    return execute(assert(bindings[self], "invalid endpoint"), { argv }, options, false)
end

-- A group yields one client result; tmux does not attribute it to each member.
function Bound:group(commands, options)
    return execute(assert(bindings[self], "invalid endpoint"), commands, options, true)
end

-- Only the private observation transport receives the pinned endpoint and lease.
function Bound:_client(open, close)
    local state = assert(bindings[self], "invalid endpoint")
    local lease
    state.active = state.active + 1
    local request = state.runtime:_operation(function(rt, operation)
        if state.invalid then
            return nil, failure("stale_generation", "endpoint generation is no longer current")
        end
        if state.client_count >= 8 then
            return nil, failure("queue_full", "endpoint observation client limit reached")
        end
        local err
        lease, err = rt:_resource(function(done)
            close(function(cleanup_error)
                state.clients[lease] = nil
                state.client_count = state.client_count - 1
                done(cleanup_error)
                cleanup(state)
            end)
        end)
        if not lease then
            return nil, err
        end
        state.clients[lease], state.client_count = true, state.client_count + 1
        local valid
        valid, err = preflight(state, operation)
        if not valid then
            return nil, err
        end
        local endpoint = {}
        for key, value in pairs(state.endpoint) do
            endpoint[key] = value
        end
        return open(rt, endpoint, lease, operation)
    end, { operation = "endpoint.observe", effect = "not_sent" })
    request:_on_retire(function()
        local value = request:result()
        if lease and not value then
            lease:close()
        end
        state.active = state.active - 1
        cleanup(state)
    end)
    -- Startup retirement can precede native cleanup or discard a delivered connection.
    local function finish_cleanup()
        if not request:is_retired() then
            return nil, failure("pending", "persistent client startup has not retired")
        end
        return lease and lease:close() or nil
    end
    return request, finish_cleanup
end

function M.bind(runtime, options)
    local copied, validation_error = options_copy(options)
    local state = {
        runtime = runtime,
        uv = runtime._driver.uv,
        options = copied,
        pending = 0,
        active = 0,
        clients = {},
        client_count = 0,
    }
    local request = runtime:_operation(function(rt, operation)
        if not copied then
            return nil, validation_error
        end
        if not state.uv then
            return nil, failure("unsupported", "endpoint requires asynchronous filesystem support")
        end
        local lease, err = rt:_resource(function(done)
            invalidate(state, "endpoint resource closed")
            state.closing, state.done = true, done
            cleanup(state)
        end)
        if not lease then
            return nil, err
        end
        state.lease = lease
        local stat
        stat, err = fs(state, "fs_lstat", { copied.socket }):await()
        if not stat or stat.type ~= "socket" then
            return nil,
                failure("invalid_endpoint", "endpoint path is not an accessible socket", err)
        end
        if not precise_integer(stat.dev) or not precise_integer(stat.ino) then
            return nil,
                failure("uncertain_generation", "socket identity is not represented precisely")
        end
        state.stat = { dev = stat.dev, ino = stat.ino }
        local parent = copied.socket:match("^(.*)/[^/]+$")
        local directory
        directory, err = fs(
            state,
            "fs_mkdtemp",
            { parent .. "/libtmux-lua-pin-XXXXXX" },
            function(value)
                state.directory = value
            end
        ):await()
        if not directory then
            return nil, err
        end
        stat, err = fs(state, "fs_lstat", { directory }):await()
        if not stat or stat.type ~= "directory" or stat.mode % 512 ~= 448 then
            return nil,
                failure("filesystem_error", "endpoint pin directory must have mode 0700", err)
        end
        state.alias = directory .. "/socket"
        local linked
        linked, err = fs(state, "fs_link", { copied.socket, state.alias }):await()
        if not linked then
            return nil, err
        end
        local valid
        valid, err = verify(state)
        if not valid then
            return nil, err
        end
        state.endpoint = {
            binary = copied.binary,
            socket = state.alias,
            config = copied.config,
            no_start = true,
        }
        state.evidence, err = read_evidence(state, operation)
        if not state.evidence then
            return nil, err
        end
        valid, err = verify(state)
        if not valid then
            return nil, err
        end
        state.generation, err = identity.generation(state.evidence)
        if not state.generation then
            return nil, err
        end
        state.methods = Bound
        local bound = setmetatable({}, {
            __metatable = "libtmux.Endpoint",
            __index = function(_, key)
                return state.methods[key]
            end,
        })
        bindings[bound], state.bound = state, true
        return bound
    end, { operation = "endpoint.bind", effect = "not_sent" })
    request:_on_retire(function()
        if state.lease and not state.bound then
            state.lease:close()
        end
    end)
    return request
end

return M
