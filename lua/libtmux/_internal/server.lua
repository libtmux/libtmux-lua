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

function Server:snapshot(options)
    return capture(servers[self], options)
end

function Server:handle(snapshot, record)
    return entities.from_snapshot(servers[self], snapshot, record)
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

---@class libtmux.ConnectOptions
---@field binary string Absolute tmux executable path.
---@field socket_path string Absolute existing daemon socket path.
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

---@class libtmux.Server
---@field observe fun(self:libtmux.Server,session:libtmux.Entity<libtmux.SnapshotSession>,
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
---@field handle fun<T>(self:libtmux.Server, snapshot:libtmux.Snapshot,
--- record:T):libtmux.Entity<T>?, libtmux.Error?
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
