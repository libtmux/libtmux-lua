local control = require("libtmux._internal.control")
local entities = require("libtmux._internal.entity")
local errors = require("libtmux._internal.error")
local metadata = require("libtmux._internal.metadata")
local M, Observation, Watch = {}, {}, {}
local observations, watches =
    setmetatable({}, { __mode = "kv" }), setmetatable({}, { __mode = "kv" })
local close_claim

local function failure(code, message)
    return errors.new(code, message, { operation = "observe", effect = "not_sent" })
end

local function rejected(runtime, err)
    return runtime:_logical_request({
        start = function(settle, retire)
            settle(nil, err)
            retire()
        end,
    })
end

local function opaque(registry, state, methods, label)
    state.methods = methods
    local object = setmetatable({}, {
        __metatable = label,
        __index = function(_, key)
            return state.methods[key]
        end,
    })
    registry[object] = state
    return object
end

local function after(request, done)
    request:_on_retire(function()
        local _, err = request:result()
        done(err)
    end)
end

local function clean_entry(entry)
    if not entry.finish or not entry.producer_retired or entry.cleaning then
        return
    end
    entry.cleaning = true
    local cleanup, err
    if entry.connection then
        cleanup = entry.connection:close()
    elseif entry.finish_cleanup then
        cleanup, err = entry.finish_cleanup()
    end
    local function done(cause)
        if entry.pool[entry.key] == entry then
            entry.pool[entry.key] = nil
        end
        entry.finish(cause)
    end
    if cleanup then
        after(cleanup, done)
    else
        done(err)
    end
end

local function close_entry(entry)
    entry.closing = true
    return entry.lease:close()
end

local function new_entry(state, pool, key, limits)
    local entry = { pool = pool, key = key, refs = 0, limits = limits }
    local err
    entry.lease, err = state.runtime:_resource(function(done)
        entry.closing, entry.finish = true, done
        if not entry.producer:is_retired() then
            entry.producer:cancel()
        end
        clean_entry(entry)
    end)
    if not entry.lease then
        return nil, err
    end
    pool[key] = entry
    entry.producer = state.runtime:_root_operation(function(rt)
        local setup
        setup, entry.finish_cleanup = control.open(rt, state.bound, limits)
        return setup:await()
    end, { operation = "observe.attach", effect = "not_sent" })
    entry.producer:_on_retire(function()
        entry.producer_retired = true
        entry.connection = entry.producer:result()
        clean_entry(entry)
    end)
    return entry
end

local function release_claim(claim)
    if claim.closed then
        return
    end
    claim.closed = true
    local entry = claim.entry
    if entry then
        entry.refs = entry.refs - 1
        if entry.refs == 0 then
            claim.final = close_entry(entry)
        end
    end
end

local function cleanup_claim(claim, done)
    release_claim(claim)
    local remaining, cause = 1, nil
    local function completed(err)
        cause = cause or err
        remaining = remaining - 1
        if remaining == 0 then
            done(cause)
        end
    end
    for pending, item in pairs(claim.pending) do
        remaining = remaining + 1
        item.finish = completed
        pending:cancel()
    end
    for watch in pairs(claim.watches) do
        remaining = remaining + 1
        after(watch.lease:close(), completed)
    end
    if claim.final then
        remaining = remaining + 1
        after(claim.final, completed)
    end
    completed()
end

close_claim = function(claim)
    release_claim(claim)
    return claim.lease:close()
end

function M.open(state, session, options)
    local runtime = state.runtime
    local ref, err = entities.inspect(state, session, "session")
    if not ref then
        return rejected(runtime, err)
    end
    local limits
    limits, err = control.prepare(options)
    if not limits then
        return rejected(runtime, err)
    end
    limits.session_id = ref.id
    local pool = state.observations or {}
    state.observations = pool
    local entry = pool[ref.id]
    if entry then
        if entry.closing then
            return rejected(runtime, failure("closing", "previous attachment is still closing"))
        end
        for key, value in pairs(limits) do
            if entry.limits[key] ~= value then
                return rejected(
                    runtime,
                    failure("option_conflict", "shared attachment limits differ")
                )
            end
        end
    end
    local claim = { server = state, pending = {}, watches = {} }
    claim.lease, err = runtime:_resource(function(done)
        cleanup_claim(claim, done)
    end)
    if not claim.lease then
        return rejected(runtime, err)
    end
    if not entry then
        entry, err = new_entry(state, pool, ref.id, limits)
        if not entry then
            close_claim(claim)
            return rejected(runtime, err)
        end
    end
    claim.entry, entry.refs = entry, entry.refs + 1
    local request = runtime:_operation(function(_, operation)
        operation:_set_effect("unknown")
        local connection, cause = entry.producer:await()
        if not connection then
            return nil, cause
        end
        local alive
        alive, cause = connection:_status()
        if not alive then
            return nil, cause
        end
        local current
        current, cause = entities.inspect(state, session, "session")
        if not current then
            return nil, cause
        end
        if claim.closed then
            return nil, failure("closed", "observation lease is closed")
        end
        operation:_set_effect("completed")
        return opaque(observations, claim, Observation, "libtmux.Observation")
    end, { operation = "observe", effect = "not_sent" })
    request:_on_retire(function()
        if not request:result() then
            close_claim(claim)
        end
    end)
    return request
end

local function watch_result(claim, native)
    local state = { native = native, owner = claim }
    local err
    state.lease, err = claim.server.runtime:_resource(function(done)
        after(native:close(), function(cause)
            claim.watches[state] = nil
            if claim.server.runtime._closing and cause and cause.code == "closed" then
                cause = nil
            end
            done(cause)
        end)
    end)
    if not state.lease then
        return nil, err
    end
    return opaque(watches, state, Watch, "libtmux.Watch"), nil, state
end

local function open_watch(claim, method, pane, names, options)
    local rt = claim.server.runtime
    if claim.closed or claim.server.closed then
        return rejected(rt, failure("closed", "observation lease is closed"))
    end
    local ref, err
    if pane then
        ref, err = entities.inspect(claim.server, pane, "pane")
        if not ref then
            return rejected(rt, err)
        end
    elseif method ~= "watch_notifications" then
        return rejected(rt, failure("invalid_target", "pane observation requires a pane handle"))
    end
    options, err = control.prepare_watch(options)
    if not options then
        return rejected(rt, err)
    end
    if method == "subscribe_format" then
        local projection
        projection, err = metadata.projection("pane", claim.server.version, names)
        if not projection then
            return rejected(rt, err)
        end
        local copy = {}
        for i, name in ipairs(names) do
            copy[i] = name
        end
        names = copy
    end
    local connection = claim.entry.connection
    local opening
    local item = {}
    local request = rt:_operation(function(_, operation)
        if claim.closed or claim.server.closed then
            return nil, failure("closed", "observation lease is closed")
        end
        operation:_set_effect("unknown")
        if method == "watch_notifications" then
            opening = connection:watch_notifications(options)
        elseif method == "subscribe_format" then
            opening = connection:subscribe_format(ref.id, names, options)
        else
            opening = connection:watch_pane(ref.id, options)
        end
        local native, cause = opening:await()
        if not native then
            return nil, cause
        end
        if claim.closed or claim.server.closed then
            return nil, failure("closed", "observation lease closed during readiness")
        end
        local generation
        generation, cause = claim.server.bound:generation()
        if not generation then
            return nil, cause
        end
        local object
        object, cause, item.watch = watch_result(claim, native)
        operation:_set_effect("completed")
        return object, cause
    end, { operation = "observe.watch", effect = "not_sent" })
    claim.pending[request] = item
    request:_on_retire(function()
        local function finish(cause)
            claim.pending[request] = nil
            if item.finish then
                item.finish(cause)
            end
        end
        if not request:result() then
            if opening then
                opening:cancel()
            end
            if item.watch then
                after(item.watch.lease:close(), finish)
            else
                local native = opening and opening:result()
                if native then
                    after(native:close(), finish)
                else
                    finish()
                end
            end
        else
            claim.watches[item.watch] = true
            finish()
        end
    end)
    if not request:is_settled() then
        local bytes = 32 + (ref and #ref.id or 0)
        for _, name in ipairs(names or {}) do
            bytes = bytes + 8 + #name
        end
        local accepted, cause = request:_retain(bytes)
        if not accepted then
            request:cancel(cause)
        end
    end
    return request
end

function Observation:watch_pane(pane, options)
    return open_watch(assert(observations[self]), "watch_pane", pane, nil, options)
end

function Observation:watch_notifications(options)
    return open_watch(assert(observations[self]), "watch_notifications", nil, nil, options)
end

function Observation:subscribe_format(pane, fields, options)
    return open_watch(assert(observations[self]), "subscribe_format", pane, fields, options)
end

function Observation:coverage()
    local claim = assert(observations[self])
    if claim.closed or claim.server.closed then
        return nil, failure("closed", "observation lease is closed")
    end
    return claim.entry.connection:coverage()
end

function Observation:close()
    return close_claim(assert(observations[self]))
end

function Watch:next(options)
    return assert(watches[self]).native:next(options)
end

function Watch:close()
    return assert(watches[self]).lease:close()
end

---@class libtmux.ObservationOptions
---@field max_bytes? integer Shared retained connection bytes; default 4194304.
---@field max_pending? integer Shared housekeeping replies; default 128.
---@field max_watches? integer Shared watches; default 128.
---@field timeout? integer Readiness timeout in milliseconds; default 750.

---@class libtmux.WatchOptions
---@field max_bytes? integer Retained event bytes; default 1048576.
---@field max_events? integer Retained events; default 1024.

---@class libtmux.ObservationCoverage
---@field session_id string
---@field panes string[]
---@field generation table Opaque connection identity, distinct after reopening.
---@field ready boolean

---@class libtmux.Observation
---@field watch_pane fun(self:libtmux.Observation,pane:libtmux.Pane,
--- options?:libtmux.WatchOptions):libtmux.Request<libtmux.Watch>
---@field watch_notifications fun(self:libtmux.Observation,
--- options?:libtmux.WatchOptions):libtmux.Request<libtmux.Watch>
---@field subscribe_format fun(self:libtmux.Observation,pane:libtmux.Pane,
--- fields:string[],options?:libtmux.WatchOptions):libtmux.Request<libtmux.Watch>
---@field coverage fun(self:libtmux.Observation):libtmux.ObservationCoverage?,libtmux.Error?
---@field close fun(self:libtmux.Observation):libtmux.Request<boolean>

---@class libtmux.ObservationEvent
---@field kind "output"|"notification"|"format"
---@field generation table
---@field server_generation table
---@field sequence integer
---@field pane? string
---@field data? string Byte-preserving pane output.
---@field age? string Extended-output decimal age.
---@field metadata? string Extended-output metadata.
---@field name? string Native notification name.
---@field payload? string Native notification payload.
---@field raw? string Original notification line.
---@field value? table Typed format subscription value.
---@field session_id? string
---@field window_id? string
---@field index? integer

---@class libtmux.Watch
---@field next fun(self:libtmux.Watch,options?:{timeout?:number,deadline?:number}):
--- libtmux.Request<libtmux.ObservationEvent>
---@field close fun(self:libtmux.Watch):libtmux.Request<boolean>

return M
