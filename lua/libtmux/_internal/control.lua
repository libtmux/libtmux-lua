local errors = require("libtmux._internal.error")
local metadata = require("libtmux._internal.metadata")
local parser = require("libtmux._internal.control_parser")
local native = require("libtmux._internal.control_io")
local M, Connection, Watch = {}, {}, {}
local connections, watches =
    setmetatable({}, { __mode = "kv" }), setmetatable({}, { __mode = "kv" })
local server_projection =
    assert(metadata.projection("server", "3.2a", { "pid", "start_time", "version", "socket_path" }))
local pane_projection = assert(metadata.projection("pane", "3.2a", { "id", "window_id" }))
local defaults = { max_bytes = 4194304, max_pending = 128, max_watches = 128, timeout = 750 }
local watch_defaults = { max_bytes = 1048576, max_events = 1024 }
local terminate, pump, housekeeping

local function failure(code, message, effect, cause, partial)
    return errors.new(code, message, {
        operation = "control",
        effect = effect or "not_sent",
        cause = cause,
        partial = partial,
    })
end

local function options_copy(options, allowed, extra)
    if options == nil then
        options = {}
    end
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return nil, failure("invalid_argument", "observation options must be a plain table")
    end
    local copy = {}
    for key, value in next, options do
        if allowed[key] == nil and key ~= extra then
            return nil, failure("invalid_argument", "unknown observation option")
        end
        copy[key] = value
    end
    for key, default in pairs(allowed) do
        local value = copy[key]
        if value == nil then
            value = default
        end
        if type(value) ~= "number" or value < 1 or value > 16777216 or value % 1 ~= 0 then
            return nil,
                failure("invalid_argument", "observation limits must be bounded positive integers")
        end
        copy[key] = value
    end
    return copy
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

local function cost(value)
    if type(value) == "string" then
        return #value
    end
    if type(value) ~= "table" then
        return 8
    end
    local result = 0
    for key, item in pairs(value) do
        if key ~= "generation" and key ~= "server_generation" then
            result = result + cost(key) + cost(item)
        end
    end
    return result
end

local function rejected(runtime, err)
    return runtime:_logical_request({
        start = function(settle, retire)
            settle(nil, err)
            retire()
        end,
    })
end

-- Every byte is quoted for tmux's line parser, not a shell or argv parser.
local function encode(argv)
    local tokens = {}
    for index, value in ipairs(argv) do
        tokens[index] = '"'
            .. value:gsub(".", function(byte)
                return string.format("\\%03o", byte:byte())
            end)
            .. '"'
    end
    return table.concat(tokens, " ") .. "\n"
end

local function release(state, amount)
    if amount > 0 then
        assert(state.budget:release(amount))
    end
end

local function drop_watch(watch, err)
    if watch.closed then
        return
    end
    watch.closed, watch.error = true, err
    watch.owner.watches[watch] = nil
    watch.owner.watch_count = watch.owner.watch_count - 1
    watch.queue = {}
    release(watch.owner, watch.bytes)
    watch.bytes, watch.data_bytes = 0, 0
    if watch.projection_bytes then
        release(watch.owner, watch.projection_bytes)
        watch.projection_bytes, watch.projection = nil, nil
    end
    if watch.waiter then
        local pending = watch.waiter
        watch.waiter = nil
        pending.settle(nil, err)
        pending.retire()
    end
    if watch.subscription then
        watch.owner.subscriptions[watch.subscription] = nil
        if not watch.owner.closed then
            watch.unsubscribe =
                housekeeping(watch.owner, { "refresh-client", "-B", watch.subscription })
            local accepted, cause = pcall(
                watch.unsubscribe.on_complete,
                watch.unsubscribe,
                function(_, cleanup_error)
                    if cleanup_error and not watch.owner.closed then
                        terminate(
                            watch.owner,
                            failure(
                                "connection_lost",
                                "format subscription cleanup failed",
                                "unknown",
                                cleanup_error
                            )
                        )
                    end
                end
            )
            if not accepted then
                terminate(
                    watch.owner,
                    failure(
                        "connection_lost",
                        "format subscription cleanup could not be supervised",
                        "unknown",
                        cause
                    )
                )
            end
        end
    end
end

local function deliver(watch, event)
    if watch.closed then
        return
    end
    local state, bytes = watch.owner, cost(event)
    local data_bytes = #(event.data or "")
    local retained, err
    if watch.bytes + bytes <= watch.limits.max_bytes and #watch.queue < watch.limits.max_events then
        retained, err = state.budget:retain(bytes)
    end
    if not retained then
        drop_watch(
            watch,
            failure("observation_gap", "observation buffer limit reached", "unknown", err, {
                dropped_bytes = watch.data_bytes + data_bytes,
                dropped_events = #watch.queue + 1,
            })
        )
        return
    end
    if watch.waiter then
        local pending = watch.waiter
        watch.waiter = nil
        local transferred, transfer_error = state.budget:transfer(pending.request, bytes)
        if transferred then
            pending.settle(event)
        else
            release(state, bytes)
            pending.settle(nil, transfer_error)
        end
        pending.retire()
    else
        watch.queue[#watch.queue + 1] = { event = event, bytes = bytes, data_bytes = data_bytes }
        watch.bytes, watch.data_bytes = watch.bytes + bytes, watch.data_bytes + data_bytes
    end
end

local function finish_slot(state, slot, body, err)
    if slot.request then
        if body then
            local retained, cause = slot.request:_retain(#body)
            if not retained then
                body, err =
                    nil,
                    failure("queue_full", "control reply byte limit reached", "completed", cause)
            end
        end
        slot.request:_set_effect("completed")
        if slot.operation then
            slot.operation:_set_effect("completed")
        end
        slot.settle(body, err)
        slot.retire()
        slot.request, slot.settle, slot.retire = nil, nil, nil
    end
    local metadata_bytes = slot.cost - (slot.line and #slot.line or 0)
    slot.cost = slot.cost - metadata_bytes
    release(state, metadata_bytes)
end

pump = function(state)
    if state.closed or state.writing then
        return
    end
    local slot
    for _, item in ipairs(state.slots) do
        if not item.written then
            slot = item
            break
        end
    end
    if not slot then
        return
    end
    slot.written, state.writing = true, true
    if slot.request then
        slot.request:_set_effect("unknown")
    end
    if slot.operation then
        slot.operation:_set_effect("unknown")
    end
    local ok, err = state.io:write(slot.line, function(write_error)
        state.writing = false
        local bytes = #slot.line
        slot.line, slot.cost = nil, slot.cost - bytes
        release(state, bytes)
        if write_error then
            terminate(
                state,
                failure("connection_lost", "control write failed", "unknown", write_error)
            )
        else
            pump(state)
        end
    end)
    if not ok then
        terminate(state, failure("connection_lost", "control write failed", "unknown", err))
    end
end

housekeeping = function(state, argv, operation)
    if state.closed then
        return rejected(
            state.runtime,
            state.error or failure("closed", "control connection is closed")
        )
    end
    local line = encode(argv)
    local retained, err = state.budget:retain(#line + 64)
    if not retained then
        return rejected(state.runtime, err)
    end
    local slot = { line = line, cost = #line + 64, operation = operation }
    local request = state.runtime:_logical_request({
        timeout = state.limits.timeout,
        effect = "not_sent",
        operation = "control.housekeeping",
        start = function(settle, retire, current)
            if state.closed or #state.slots >= state.limits.max_pending then
                settle(
                    nil,
                    state.error or failure("queue_full", "control reply queue limit reached")
                )
                retire()
                return
            end
            slot.request, slot.settle, slot.retire, slot.admitted = current, settle, retire, true
            state.slots[#state.slots + 1] = slot
            pump(state)
            return function(reason)
                reason.effect = slot.written and "unknown" or "not_sent"
                slot.request, slot.settle, slot.retire = nil, nil, nil
                slot.operation = nil
                if not slot.written then
                    for index, item in ipairs(state.slots) do
                        if item == slot then
                            table.remove(state.slots, index)
                            break
                        end
                    end
                    slot.line = nil
                    release(state, slot.cost)
                    slot.cost = 0
                end
                -- The connection owns a written tombstone; cancellation cannot shift FIFO.
                retire()
                if reason.code == "deadline_exceeded" and slot.written then
                    terminate(
                        state,
                        failure(
                            "connection_lost",
                            "control reply deadline exceeded",
                            "unknown",
                            reason
                        )
                    )
                end
            end
        end,
    })
    request:_on_retire(function()
        if not slot.admitted then
            slot.line = nil
            release(state, slot.cost)
            slot.cost = 0
        end
    end)
    return request
end

terminate = function(state, err, closing)
    if state.closed then
        return
    end
    state.closed, state.ready, state.error = true, false, err
    for watch in pairs(state.watches) do
        drop_watch(watch, err)
    end
    for _, slot in ipairs(state.slots) do
        if slot.request then
            slot.settle(
                nil,
                failure(
                    err and err.code or "closed",
                    err and err.message or "control connection closed",
                    slot.written and "unknown" or "not_sent",
                    err
                )
            )
            slot.retire()
            slot.request, slot.settle, slot.retire = nil, nil, nil
        end
    end
    if state.bootstrap then
        state.bootstrap.settle(
            nil,
            err or failure("closed", "control connection closed during bootstrap")
        )
        state.bootstrap.retire()
        state.bootstrap = nil
    end
    if state.lease and not closing then
        state.lease:close()
    end
end

local function invalidate_coverage(state, window)
    state.coverage_current = false
    if state.ready then
        for watch in pairs(state.watches) do
            if watch.pane and (not window or state.pane_set[watch.pane] == window) then
                drop_watch(
                    watch,
                    failure(
                        "observation_gap",
                        "pane coverage changed; reopen observation",
                        "unknown"
                    )
                )
            end
        end
    end
end

local function event(state, item)
    if state.closed then
        return
    end
    if item.kind == "block" then
        if item.phase == "bootstrap" then
            if state.booted or item.ending ~= "end" then
                terminate(
                    state,
                    failure("protocol_error", "control attachment bootstrap failed", "unknown")
                )
                return
            end
            state.booted = true
            if state.bootstrap then
                state.bootstrap.settle(true)
                state.bootstrap.retire()
                state.bootstrap = nil
            end
        else
            local slot = table.remove(state.slots, 1)
            if not slot or not slot.written then
                terminate(
                    state,
                    failure(
                        "protocol_error",
                        "control response has no committed request",
                        "unknown"
                    )
                )
                return
            end
            finish_slot(
                state,
                slot,
                item.ending == "end" and item.body or nil,
                item.ending ~= "end"
                        and failure("protocol_error", "control housekeeping failed", "completed")
                    or nil
            )
        end
        return
    end
    state.sequence = state.sequence + 1
    if item.name == "session-changed" then
        local session = item.payload:match("^(%$[0-9]+) ")
        if session ~= state.session_id then
            terminate(
                state,
                failure("observation_gap", "control attachment changed session", "unknown")
            )
            return
        end
        state.attached = true
    elseif item.name == "exit" then
        terminate(state, failure("connection_lost", "control client detached", "unknown"))
        return
    elseif
        item.name == "layout-change"
        or item.name == "window-close"
        or item.name == "window-add"
    then
        state.epoch = state.epoch + 1
        invalidate_coverage(state)
    elseif item.name == "unlinked-window-close" then
        state.epoch = state.epoch + 1
        local window = item.payload:match("^(@[0-9]+)$")
        for _, covered_window in pairs(state.pane_set) do
            if covered_window == window then
                invalidate_coverage(state, window)
                break
            end
        end
    elseif item.name == "pause" then
        local pane = item.payload:match("^(%%[0-9]+)")
        for watch in pairs(state.watches) do
            if watch.pane == pane then
                drop_watch(watch, failure("observation_gap", "tmux paused pane output", "unknown"))
            end
        end
    end
    if item.name == "subscription-changed" then
        local name, session, window, index, pane, value =
            item.payload:match("^(%S+) (%$[0-9]+) (@[0-9]+) ([0-9]+) (%%[0-9]+) : (.*)$")
        local watch = name and state.subscriptions[name]
        if watch then
            local rows, err = metadata.decode(
                value .. "\n",
                watch.projection,
                { max_rows = 1, max_bytes = 65536 }
            )
            local numeric_index = tonumber(index)
            if
                session ~= state.session_id
                or pane ~= watch.pane
                or not rows
                or #rows ~= 1
                or not numeric_index
                or numeric_index > 2147483647
            then
                drop_watch(
                    watch,
                    failure(
                        "observation_gap",
                        "format subscription response is malformed",
                        "unknown",
                        err
                    )
                )
            else
                deliver(watch, {
                    kind = "format",
                    generation = state.generation,
                    server_generation = state.server_generation,
                    sequence = state.sequence,
                    pane = pane,
                    session_id = session,
                    window_id = window,
                    index = numeric_index,
                    value = rows[1],
                })
            end
        end
    end
    for watch in pairs(state.watches) do
        if
            (watch.pane and not watch.projection and item.pane == watch.pane and item.data)
            or watch.notifications
        then
            local copy = {
                generation = state.generation,
                server_generation = state.server_generation,
                sequence = state.sequence,
            }
            if watch.pane then
                copy.kind, copy.pane, copy.data = "output", item.pane, item.data
                copy.age, copy.metadata = item.age, item.metadata
            else
                for key, value in pairs(item) do
                    copy[key] = value
                end
            end
            deliver(watch, copy)
        end
    end
end

local function consume(state, data)
    if state.closed then
        return
    end
    if #data > 1048576 then
        terminate(state, failure("frame_limit", "control input chunk limit reached", "unknown"))
        return
    end
    -- Small slices bound parser event count even for many short notifications.
    for start = 1, #data, 256 do
        if state.closed then
            break
        end
        local part = data:sub(start, start + 255)
        local temporary = #part * 8 + 128
        local retained, cause = state.budget:retain(temporary)
        if not retained then
            terminate(
                state,
                failure("queue_full", "control parser byte limit reached", "unknown", cause)
            )
            return
        end
        local items, err = state.parser:feed(part)
        for _, item in ipairs(items) do
            if item.kind ~= "error" then
                event(state, item)
            end
        end
        local remaining = state.parser:stats().retained_bytes
        release(state, state.parser_bytes + temporary - remaining)
        state.parser_bytes = remaining
        if err then
            terminate(state, failure("protocol_error", "control framing failed", "unknown", err))
        end
    end
end

local function coverage(state, operation)
    local epoch = state.epoch
    local body, err = housekeeping(state, {
        "list-panes",
        "-s",
        "-t",
        state.session_id,
        "-F",
        assert(metadata.format(pane_projection)),
    }, operation):await()
    if not body then
        return nil, err
    end
    local rows
    rows, err = metadata.decode(body, pane_projection, { max_rows = 4096, max_bytes = 262144 })
    if not rows then
        local malformed =
            failure("protocol_error", "control coverage response is malformed", "completed", err)
        terminate(state, malformed)
        return nil, malformed
    end
    if not state.attached or state.epoch ~= epoch or state.closed then
        return nil,
            failure("observation_gap", "control coverage changed during readiness", "completed")
    end
    local panes, set = {}, {}
    for _, row in ipairs(rows) do
        if
            not row.id:match("^%%[0-9]+$")
            or not row.window_id:match("^@[0-9]+$")
            or (set[row.id] and set[row.id] ~= row.window_id)
        then
            local malformed =
                failure("protocol_error", "control coverage contains an invalid pane", "completed")
            terminate(state, malformed)
            return nil, malformed
        end
        if not set[row.id] then
            set[row.id], panes[#panes + 1] = row.window_id, row.id
        end
    end
    local bytes = 0
    for _, pane in ipairs(panes) do
        bytes = bytes + #pane * 2 + #set[pane]
    end
    local retained, cause = state.budget:retain(bytes)
    if not retained then
        return nil, cause
    end
    state.panes, state.pane_set = panes, set
    release(state, state.coverage_bytes)
    state.coverage_bytes = bytes
    state.coverage_current = true
    return true
end

function Connection:coverage()
    local state = assert(connections[self], "invalid control connection")
    if state.closed then
        return nil, state.error or failure("closed", "control connection is closed")
    end
    if not state.coverage_current then
        return nil, failure("observation_gap", "control coverage needs a new readiness barrier")
    end
    local panes = {}
    for index, pane in ipairs(state.panes) do
        panes[index] = pane
    end
    return {
        session_id = state.session_id,
        panes = panes,
        generation = state.generation,
        ready = state.ready,
    }
end

local function open_watch(state, pane, options, notifications, projection)
    local limits, err = options_copy(options, watch_defaults)
    if not limits then
        return rejected(state.runtime, err)
    end
    if pane and (type(pane) ~= "string" or #pane > 32 or not pane:match("^%%[0-9]+$")) then
        return rejected(
            state.runtime,
            failure("invalid_argument", "pane observation requires a literal pane ID")
        )
    end
    local projection_bytes = 0
    if projection then
        projection_bytes = #assert(metadata.format(projection))
            + cost(assert(metadata.schema(projection)))
        local retained, cause = state.budget:retain(projection_bytes)
        if not retained then
            return rejected(state.runtime, cause)
        end
    end
    local watch
    local request = state.runtime:_operation(function(_, operation)
        if state.closed then
            return nil, state.error or failure("closed", "control connection is closed")
        end
        if state.watch_count >= state.limits.max_watches then
            return nil, failure("queue_full", "control watch limit reached")
        end
        watch = {
            owner = state,
            limits = limits,
            pane = pane,
            notifications = notifications,
            queue = {},
            bytes = 0,
            data_bytes = 0,
            projection = projection,
            projection_bytes = projection_bytes,
        }
        state.watches[watch], state.watch_count = true, state.watch_count + 1
        local valid, cause = coverage(state, operation)
        if not valid then
            return nil, cause
        end
        if watch.closed then
            return nil, watch.error
        end
        if pane and not state.pane_set[pane] then
            return nil,
                failure("uncovered_pane", "pane is outside the attached session", "completed")
        end
        if projection then
            local format = assert(metadata.format(projection))
            state.subscription_number = state.subscription_number + 1
            watch.subscription = "libtmux_" .. state.subscription_number
            state.subscriptions[watch.subscription] = watch
            local response, subscription_error = housekeeping(state, {
                "refresh-client",
                "-B",
                watch.subscription .. ":" .. pane .. ":" .. format,
            }, operation):await()
            if response == nil then
                return nil, subscription_error
            end
            if response ~= "" then
                return nil,
                    failure(
                        "protocol_error",
                        "format subscription acknowledgement is malformed",
                        "completed"
                    )
            end
            if watch.closed then
                return nil, watch.error
            end
        end
        operation:_set_effect("completed")
        return opaque(watches, watch, Watch, "libtmux.Watch")
    end, { operation = "control.watch", effect = "not_sent" })
    request:_on_retire(function()
        local value = request:result()
        if watch and not value then
            drop_watch(watch)
        elseif not watch then
            release(state, projection_bytes)
        end
    end)
    return request
end

function Connection:watch_pane(pane, options)
    return open_watch(assert(connections[self], "invalid control connection"), pane, options, false)
end

function Connection:watch_notifications(options)
    return open_watch(assert(connections[self], "invalid control connection"), nil, options, true)
end

function Connection:subscribe_format(pane, names, options)
    local state = assert(connections[self], "invalid control connection")
    local projection, err = metadata.projection("pane", state.version, names)
    if not projection then
        return rejected(state.runtime, err)
    end
    return open_watch(state, pane, options, false, projection)
end

function Connection:close()
    local state = assert(connections[self], "invalid control connection")
    terminate(state, nil, true)
    return state.lease:close()
end

function Watch:next(options)
    local watch = assert(watches[self], "invalid watch")
    if options == nil then
        options = {}
    end
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return rejected(
            watch.owner.runtime,
            failure("invalid_argument", "watch read options must be a plain table")
        )
    end
    for key in next, options do
        if key ~= "timeout" and key ~= "deadline" then
            return rejected(
                watch.owner.runtime,
                failure("invalid_argument", "unknown watch read option")
            )
        end
    end
    return watch.owner.runtime:_logical_request({
        timeout = rawget(options, "timeout"),
        deadline = rawget(options, "deadline"),
        operation = "watch.next",
        effect = "not_sent",
        start = function(settle, retire, request)
            if watch.waiter then
                settle(nil, failure("concurrent_read", "watch already has a pending read"))
                retire()
            elseif #watch.queue > 0 then
                local item = table.remove(watch.queue, 1)
                watch.bytes, watch.data_bytes =
                    watch.bytes - item.bytes, watch.data_bytes - item.data_bytes
                local transferred, err = watch.owner.budget:transfer(request, item.bytes)
                if transferred then
                    settle(item.event)
                else
                    release(watch.owner, item.bytes)
                    settle(nil, err)
                end
                retire()
            elseif watch.closed then
                settle(nil, watch.error)
                retire()
            else
                watch.waiter = { settle = settle, retire = retire, request = request }
                return function()
                    if watch.waiter and watch.waiter.request == request then
                        watch.waiter = nil
                    end
                    retire()
                end
            end
        end,
    })
end

function Watch:close()
    local watch = assert(watches[self], "invalid watch")
    drop_watch(watch)
    if not watch.close_request then
        if watch.unsubscribe then
            watch.close_request = watch.owner.runtime:_operation(function()
                local value, err = watch.unsubscribe:await()
                if value == nil then
                    return nil, err
                end
                return true
            end)
            return watch.close_request
        end
        watch.close_request = watch.owner.runtime:_logical_request({
            start = function(settle, retire)
                settle(true)
                retire()
            end,
        })
    end
    return watch.close_request
end

function M.open(runtime, bound, options)
    local limits, validation_error = options_copy(options, defaults, "session_id")
    if not limits then
        return rejected(runtime, validation_error)
    end
    if
        type(limits.session_id) ~= "string"
        or #limits.session_id > 32
        or not limits.session_id:match("^%$[0-9]+$")
    then
        return rejected(
            runtime,
            failure("invalid_argument", "observation attachment requires a literal session ID")
        )
    end
    local generation, generation_error = bound:generation()
    if not generation then
        return rejected(runtime, generation_error)
    end
    local evidence = assert(bound:evidence())
    local state = {
        runtime = runtime,
        limits = limits,
        session_id = limits.session_id,
        server_generation = generation,
        generation = {},
        slots = {},
        watches = {},
        watch_count = 0,
        sequence = 0,
        epoch = 0,
        parser_bytes = 0,
        coverage_bytes = 0,
        panes = {},
        pane_set = {},
        subscriptions = {},
        subscription_number = 0,
        version = evidence.version,
    }
    return bound:_client(function(rt, endpoint, lease, operation)
        if state.closed then
            return nil, failure("closed", "observation closed before attachment")
        end
        state.lease, state.budget = lease, assert(lease:_budget(limits.max_bytes))
        state.parser = assert(parser.new({ bootstrap = true, max_block_bytes = 262144 }))
        local bootstrap = rt:_logical_request({
            timeout = limits.timeout,
            effect = "unknown",
            operation = "control.bootstrap",
            start = function(settle, retire)
                if state.closed then
                    settle(nil, state.error)
                    retire()
                elseif state.booted then
                    settle(true)
                    retire()
                else
                    state.bootstrap = { settle = settle, retire = retire }
                end
                return function(reason)
                    state.bootstrap = nil
                    retire()
                    terminate(
                        state,
                        failure("connection_lost", "control bootstrap cancelled", "unknown", reason)
                    )
                end
            end,
        })
        local err
        state.io, err = native.start(rt, endpoint, limits, function(data)
            consume(state, data)
        end, function(cause)
            local _, parse_error = state.parser:finish(cause)
            if not state.closed then
                terminate(
                    state,
                    failure(
                        "connection_lost",
                        "control output ended",
                        "unknown",
                        parse_error or cause
                    )
                )
            end
        end)
        if err then
            terminate(state, err)
            return nil, err
        end
        operation:_set_effect("unknown")
        local ready
        ready, err = bootstrap:await()
        if not ready then
            return nil, err
        end
        local body
        body, err = housekeeping(
            state,
            { "display-message", "-p", assert(metadata.format(server_projection)) },
            operation
        ):await()
        if not body then
            return nil, err
        end
        local rows
        rows, err = metadata.decode(body, server_projection, { max_rows = 1, max_bytes = 16384 })
        local row = rows and rows[1]
        if
            not row
            or #rows ~= 1
            or string.format("%.0f", row.pid) ~= evidence.pid
            or string.format("%.0f", row.start_time) ~= evidence.started
            or row.version ~= evidence.version
            or row.socket_path ~= evidence.socket
        then
            return nil,
                failure(
                    "stale_generation",
                    "control daemon evidence does not match the endpoint",
                    "completed",
                    err
                )
        end
        ready, err = coverage(state, operation)
        if not ready then
            return nil, err
        end
        state.ready = true
        operation:_set_effect("completed")
        return opaque(connections, state, Connection, "libtmux.Connection")
    end, function(done)
        terminate(
            state,
            failure("observation_gap", "endpoint observation lease closed", "unknown"),
            true
        )
        local function finish(err)
            state.slots, state.panes, state.pane_set, state.parser = {}, {}, {}, nil
            if state.budget then
                release(state, state.budget:bytes())
            end
            done(err)
        end
        if state.io then
            state.io:close(finish)
        else
            finish()
        end
    end)
end

return M
