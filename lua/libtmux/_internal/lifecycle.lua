local codec = require("libtmux._internal.codec")
local command = require("libtmux._internal.command")
local domain = require("libtmux._internal.domain")
local errors = require("libtmux._internal.error")
local identity = require("libtmux._internal.identity")
local M, Owner = {}, {}
local owners = setmetatable({}, { __mode = "k" })
local queues = setmetatable({}, { __mode = "k" })
local token_option = "@libtmux_owner_generation"
local pane_option = "@libtmux_pane_key"
local fields =
    { "pid", "start_time", token_option, "session_id", "window_id", "pane_id", "window_index" }
local creation_format = assert(codec.format(fields))
local prefixes = { session = "$", window = "@", pane = "%" }

local function failure(code, message, details)
    details = details or {}
    details.operation, details.effect = "lifecycle", details.effect or "not_sent"
    return errors.new(code, message, details)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function copy_options(options)
    local entries, bytes = 0, 0
    local function copy(value, depth)
        if type(value) == "string" then
            bytes = bytes + #value
            if bytes > 1048576 then
                error(failure("invalid_options", "lifecycle input exceeds one MiB"), 0)
            end
        elseif type(value) == "table" then
            if not plain(value) or depth > 4 then
                error(
                    failure("invalid_options", "lifecycle options require bounded plain records"),
                    0
                )
            end
            local result = {}
            for key, item in pairs(value) do
                entries = entries + 1
                if entries > 4096 or (type(key) ~= "number" and type(key) ~= "string") then
                    error(
                        failure("invalid_options", "lifecycle options exceed their entry limit"),
                        0
                    )
                end
                result[key] = copy(item, depth + 1)
            end
            return result
        end
        return value
    end
    local ok, copied = pcall(copy, options or {}, 0)
    if not ok then
        return nil, copied
    end
    return copied
end

local function valid_token(value)
    return type(value) == "string" and #value == 32 and value:match("^[0-9a-fA-F]+$") ~= nil
end

local function decimal(value, positive)
    return type(value) == "string"
        and value:match("^[0-9]+$")
        and (not positive or value:find("[1-9]"))
end

local function nonce(uv)
    local bytes, cause = uv.random(16)
    if not bytes or #bytes ~= 16 then
        return nil, failure("unsupported", "cannot obtain ownership randomness", { cause = cause })
    end
    return (
        bytes:gsub(".", function(byte)
            return string.format("%02x", byte:byte())
        end)
    )
end

local function program(commands)
    return assert(command.prepare_program({ commands = commands }, true))
end

local function condition(receipt)
    return "#{&&:#{==:#{pid},"
        .. receipt.pid
        .. "},#{&&:#{==:#{start_time},"
        .. receipt.started
        .. "},#{==:#{"
        .. token_option
        .. "},"
        .. receipt.token
        .. "}}}"
end

local function guarded(receipt, commands)
    return {
        "if-shell",
        "-F",
        condition(receipt),
        program(commands),
        program({ { "display-message", "-p", "libtmux-stale-owner" } }),
    }
end

local function current(state, reference)
    if state.closed then
        return nil, failure("closed", "server handle is closed")
    end
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    if reference then
        local ref
        ref, err = identity.inspect(generation, reference)
        if not ref then
            return nil, err
        end
        return generation, ref
    end
    return generation
end

local function proc(uv, pid)
    local fd, cause = uv.fs_open("/proc/" .. pid .. "/stat", "r", 0)
    if not fd then
        if tostring(cause):match("^ENOENT") then
            return { gone = true }
        end
        return nil, cause
    end
    local text, err = uv.fs_read(fd, 16384, 0)
    uv.fs_close(fd)
    local rest = text and text:match("^%d+ %b() (.*)$")
    -- Process names may contain parentheses; the final ') ' starts the fields.
    if text then
        rest = text:match("^%d+ %(.*%) (.*)$")
    end
    if not rest then
        return nil, err or "malformed process identity"
    end
    local values = {}
    for field in rest:gmatch("%S+") do
        values[#values + 1] = field
    end
    if not decimal(values[20], false) then
        return nil, "missing process start tick"
    end
    return { start = values[20], gone = values[1] == "Z" or values[1] == "X" }
end

local function process_exited(stored)
    local observed, err = proc(stored.state.runtime._driver.uv, stored.receipt.pid)
    if not observed then
        return nil, err
    end
    return observed.gone or observed.start ~= stored.process_start
end

local function wait_exit(stored)
    local runtime = stored.state.runtime
    return runtime:_request({
        bytes = 0,
        timeout = 750,
        operation = "owner.exit",
        start = function(settle, retire)
            local timer = runtime._driver.uv.new_timer()
            local finished = false
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
            local function check()
                local gone, err = process_exited(stored)
                if gone then
                    finish(true)
                elseif gone == nil then
                    finish(
                        nil,
                        failure(
                            "uncertain_exit",
                            "cannot observe accepted daemon exit",
                            { cause = err }
                        )
                    )
                end
            end
            timer:start(0, 5, check)
            return function(err)
                finish(nil, err)
            end
        end,
    })
end

local function parse(result, kind, expected, generation)
    local rows, cause
    if result then
        rows, cause = codec.decode(result.stdout, 7, { max_rows = 1, max_bytes = 16384 })
    end
    local row = rows and rows[1]
    if
        not row
        or #rows ~= 1
        or not decimal(row[1], true)
        or not decimal(row[2], false)
        or not valid_token(row[3])
    then
        return nil,
            failure(
                "invalid_receipt",
                "ownership requires one complete daemon receipt",
                { cause = cause, partial = result, effect = "unknown" }
            )
    end
    local receipt =
        { pid = row[1], started = row[2], token = row[3], kind = kind, generation = generation }
    if kind ~= "server" then
        for i, key in ipairs({ "session", "window", "pane" }) do
            if not row[i + 3]:match("^" .. "%" .. prefixes[key] .. "[0-9]+$") then
                return nil,
                    failure(
                        "invalid_receipt",
                        "ownership receipt has an invalid object ID",
                        { partial = result, effect = "unknown" }
                    )
            end
            receipt[key] = row[i + 3]
        end
        if not decimal(row[7], false) or tonumber(row[7]) > 2147483647 then
            return nil,
                failure(
                    "invalid_receipt",
                    "ownership receipt has an invalid window index",
                    { partial = result, effect = "unknown" }
                )
        end
        receipt.index, receipt.id = tonumber(row[7]), receipt[kind]
        if expected and receipt.id ~= expected then
            return nil,
                failure(
                    "invalid_receipt",
                    "ownership receipt identifies another object",
                    { partial = result, effect = "unknown" }
                )
        end
    end
    return receipt
end

local function wrap_owner(state, value, receipt, process_start)
    local stored = {
        state = state,
        value = value,
        receipt = receipt,
        process_start = process_start,
        unpin = state.bound:_hold(),
    }
    local owner = setmetatable({}, {
        __index = function(_, key)
            if key == "value" then
                return stored.value
            end
            if key == "closed" then
                return stored.closed == true
            end
            if key == "cleanup_error" then
                return stored.cleanup_error
            end
            return Owner[key]
        end,
        __metatable = "libtmux.Owned",
    })
    owners[owner] = stored
    return owner
end

local function owner_from_receipt(state, receipt, wrap, value)
    local evidence, err = state.bound:evidence()
    if not evidence or evidence.pid ~= receipt.pid or evidence.started ~= receipt.started then
        return nil, err or failure("stale_generation", "receipt does not identify the bound daemon")
    end
    local observed, cause = proc(state.runtime._driver.uv, receipt.pid)
    if not observed or observed.gone then
        return nil,
            failure(
                "uncertain_generation",
                "cannot accept live daemon process identity",
                { cause = cause }
            )
    end
    if not value then
        value, err =
            wrap(state, { kind = receipt.kind, id = receipt.id, generation = receipt.generation })
    end
    return wrap_owner(state, value, receipt, observed.start), err
end

function Owner:receipt()
    local result = {}
    for key, value in pairs(owners[self].receipt) do
        if key ~= "generation" then
            result[key] = value
        end
    end
    return result
end

function Owner:release()
    local stored = owners[self]
    if stored.inflight and not stored.inflight:is_retired() then
        return nil, failure("busy", "cannot release ownership during cleanup")
    end
    stored.released = true
    stored.unpin()
    if stored.on_release then
        stored.on_release()
    end
    return stored.value
end

function Owner:close()
    local stored = owners[self]
    if stored.inflight and not stored.inflight:is_retired() then
        return stored.inflight
    end
    local state, receipt = stored.state, stored.receipt
    local request = state.runtime:_operation(function()
        if stored.closed or stored.released then
            return true
        end
        local gone, cause = process_exited(stored)
        if gone then
            stored.closed = true
            return true
        end
        if gone == nil then
            return nil,
                failure(
                    "uncertain_exit",
                    "cannot verify accepted daemon process",
                    { cause = cause }
                )
        end
        local commands = { { "kill-" .. receipt.kind } }
        if receipt.id then
            commands[1][2], commands[1][3] = "-t", receipt.id
        end
        local result, err = state.bound
            :execute(guarded(receipt, commands), { timeout = 750, max_output_bytes = 16384 })
            :await()
        if not result then
            local exited = process_exited(stored)
            if exited then
                stored.closed = true
                return true
            end
            -- Exact IDs cannot be reused in one daemon generation. Confirm absence
            -- through a successful guarded listing rather than parsing locale text.
            if receipt.id then
                local listing = "list-" .. receipt.kind .. "s"
                local argv = { listing, "-F", "#{" .. receipt.kind .. "_id}" }
                if receipt.kind ~= "session" then
                    table.insert(argv, 2, "-a")
                end
                local observed, observe_error =
                    state.bound:execute(guarded(receipt, { argv }), { timeout = 750 }):await()
                if observed and observed.stdout ~= "libtmux-stale-owner\n" then
                    local found = false
                    for id in observed.stdout:gmatch("[^\n]+") do
                        if not id:match("^%" .. prefixes[receipt.kind] .. "[0-9]+$") then
                            return nil,
                                failure("invalid_receipt", "cleanup listing contains malformed IDs")
                        end
                        if id == receipt.id then
                            found = true
                        end
                    end
                    if not found then
                        stored.closed = true
                        return true
                    end
                end
                if observe_error then
                    err.observation_error = observe_error
                end
            end
            return nil, err
        end
        if result.stdout == "libtmux-stale-owner\n" then
            return nil,
                failure("stale_generation", "reserved generation token changed; cleanup refused")
        end
        if result.stdout ~= "" or result.stderr ~= "" then
            return nil,
                failure(
                    "invalid_receipt",
                    "cleanup returned unexpected output",
                    { partial = result }
                )
        end
        if receipt.kind == "server" then
            local exited, exit_error = wait_exit(stored):await()
            if not exited then
                return nil, exit_error
            end
        end
        stored.closed, stored.cleanup_error = true, nil
        return true
    end, { operation = "owner.close", effect = "not_sent" })
    do
        local remote = request
        request = state.runtime:_operation(function()
            local value, err = remote:await()
            if not value and not stored.finalize then
                return nil, err
            end
            if stored.released then
                return true
            end
            if stored.finalize then
                value, err = stored.finalize():await()
                if not value then
                    return nil, err
                end
                -- Foreground startup also owns a native child handle. That exact
                -- process remains ours when the published socket is replaced.
                stored.closed, stored.cleanup_error = true, nil
            end
            local retired = stored.unpin()
            if retired then
                return retired:await()
            end
            return true
        end, { operation = "owner.retire", effect = "not_sent" })
    end
    stored.inflight = request
    request:_on_retire(function()
        local _, err = request:result()
        if err then
            stored.cleanup_error, stored.closed = err, false
        end
    end)
    return request
end

function M.transfer(owner)
    local stored = owners[owner]
    stored.released = true
    local transferred = wrap_owner(stored.state, stored.value, stored.receipt, stored.process_start)
    stored.unpin()
    owners[transferred].finalize, owners[transferred].on_release =
        stored.finalize, stored.on_release
    return transferred
end

function M.attach(owner, finalize, on_release)
    owners[owner].finalize, owners[owner].on_release = finalize, on_release
end

local function register(runtime, holder)
    return runtime:defer(function()
        if holder.owner then
            return holder.owner:close():await()
        end
        return true
    end)
end

function M.adopt(state, reference, value, wrap)
    local generation, ref = current(state, reference)
    local holder = {}
    local registered, registration_error = register(state.runtime, holder)
    return state.runtime:_operation(function()
        if not registered then
            return nil, registration_error
        end
        if not generation then
            return nil, ref
        end
        local kind, id = ref and ref.kind or "server", ref and ref.id
        if kind ~= "server" and not prefixes[kind] then
            return nil,
                failure("invalid_target", "ownership requires a server, session, window or pane")
        end
        local token, err = nonce(state.runtime._driver.uv)
        if not token then
            return nil, err
        end
        local display = { "display-message", "-p" }
        if id then
            display[#display + 1], display[#display + 2] = "-t", id
        end
        display[#display + 1] = creation_format
        local result
        result, err = state.bound
            :group(
                { { "set-option", "-soq", token_option, token }, display },
                { timeout = 750, max_output_bytes = 16384 }
            )
            :await()
        if not result then
            return nil, err
        end
        if result.exit_code ~= 0 or result.stderr ~= "" then
            return nil,
                failure("accept_failed", "cannot accept object ownership", { partial = result })
        end
        local receipt
        receipt, err = parse(result, kind, id, generation)
        if not receipt then
            return nil, err
        end
        holder.owner, err = owner_from_receipt(state, receipt, wrap, value)
        return holder.owner, err
    end, { operation = "adopt", effect = "not_sent" })
end

function M.create(state, parent, kind, options, wrap)
    local generation, ref = current(state, parent)
    local plan, preparation_error
    if generation then
        local ok, prepared = pcall(domain.prepare, state.runtime, kind, ref, options)
        if ok then
            plan = prepared
        else
            preparation_error = prepared
        end
    else
        preparation_error = ref
    end
    local holder = {}
    local registered, registration_error = register(state.runtime, holder)
    return state.runtime:_operation(function(rt)
        if not registered then
            return nil, registration_error
        end
        if not plan then
            return nil, preparation_error
        end
        local handed_off, attempted, receipt_error = false, false, nil
        local deferred, defer_error = rt:defer(function()
            if handed_off then
                return true
            end
            if holder.owner then
                local cleaned, err = holder.owner:close():await()
                if not cleaned then
                    return nil,
                        failure(
                            "rollback_failed",
                            "created object cleanup failed; retry through owner",
                            { cause = err, owner = holder.owner }
                        )
                end
            elseif attempted then
                return nil,
                    failure(
                        "creation_unknown",
                        "creation has no complete accepted receipt; cleanup cannot guess a target",
                        { cause = receipt_error, effect = "unknown" }
                    )
            end
            return true
        end)
        if not deferred then
            return nil, defer_error
        end
        if plan.cwd then
            local valid, err = domain.directory(state, plan.cwd):await()
            if not valid then
                return nil, err
            end
        end
        local token, err = nonce(rt._driver.uv)
        if not token then
            return nil, err
        end
        local accepted
        accepted, err = state.bound
            :group({
                { "set-option", "-soq", token_option, token },
                { "display-message", "-p", creation_format },
            }, { timeout = 750, max_output_bytes = 16384 })
            :await()
        if not accepted then
            return nil, err
        end
        local before
        before, err = parse(accepted, "server", nil, generation)
        if not before then
            return nil, err
        end
        for index, value in ipairs(plan.argv) do
            if value == "-F" then
                plan.argv[index + 1] = creation_format
                break
            end
        end
        local acquisition = state.bound:_receipt(
            { guarded(before, { plan.argv }) },
            plan.options,
            function(result, cause)
                attempted = not cause or cause.effect ~= "not_sent"
                if result and result.stdout == "libtmux-stale-owner\n" then
                    attempted, receipt_error =
                        false, failure("stale_generation", "generation changed before creation")
                    return
                end
                local receipt
                receipt, receipt_error = parse(result, kind, nil, generation)
                if receipt and kind == "window" and (not ref or receipt.session ~= ref.id) then
                    receipt, receipt_error =
                        nil, failure("invalid_receipt", "created window belongs to another session")
                end
                if receipt then
                    holder.owner, receipt_error = owner_from_receipt(state, receipt, wrap)
                end
            end
        )
        local result
        result, err = acquisition:await()
        if not result then
            return nil, err
        end
        if result.exit_code ~= 0 or result.stderr ~= "" then
            return nil,
                failure(
                    "create_failed",
                    "tmux creation failed",
                    { partial = result, owner = holder.owner, effect = "completed" }
                )
        end
        if receipt_error then
            receipt_error.owner = holder.owner
            return nil, receipt_error
        end
        if not holder.owner then
            return nil, failure("invalid_receipt", "creation did not yield an accepted owner")
        end
        handed_off = true
        return holder.owner
    end, { operation = "owned_" .. kind, effect = "not_sent" })
end

function M.scoped_create(state, parent, kind, options, wrap, body)
    local copied, err = copy_options(options)
    return state.runtime:_operation(function()
        if not copied then
            return nil, err
        end
        if type(body) ~= "function" then
            return nil, failure("invalid_callback", "owned scope requires a function")
        end
        local owner, cause = M.create(state, parent, kind, copied, wrap):await()
        if not owner then
            return nil, cause
        end
        return body(owner.value, owner)
    end, { operation = "owned_scope", effect = "not_sent" })
end

function Owner:scope(body)
    local stored = owners[self]
    return stored.state.runtime:_operation(function(rt)
        if type(body) ~= "function" then
            return nil, failure("invalid_callback", "owned scope requires a function")
        end
        local ok, err = rt:defer(function()
            return self:close():await()
        end)
        if not ok then
            return nil, err
        end
        return body(stored.value, self)
    end, { operation = "owned_scope", effect = "not_sent" })
end

local function key_text(value)
    return type(value) == "string"
        and #value > 0
        and #value <= 1024
        and not value:find("[%z\001-\031\127]")
end

function M.find(state, parent, kind, key, options, wrap)
    local generation, ref = current(state, parent)
    local rt, holder = state.runtime, {}
    local registered, registration_error = register(rt, holder)
    local copied, invalid = copy_options(options)
    if type(copied) ~= "table" or not plain(copied) then
        copied, invalid =
            {},
            invalid or failure("invalid_options", "find-or-create options must be a plain record")
    end
    if
        not key_text(key)
        or (kind ~= "pane" and key:find("\\", 1, true))
        or (kind == "session" and key:find("[.:]"))
    then
        invalid = failure(
            "invalid_options",
            "lookup names exclude backslashes; session names also exclude dots and colons"
        )
    end
    if kind ~= "pane" then
        if copied.name and copied.name ~= key then
            invalid = failure("invalid_options", "creation name must match the lookup name")
        end
        copied.name = key
    end
    local bucket = queues[rt] or {}
    queues[rt] = bucket
    local endpoint = state.endpoint.socket
    local previous = bucket[endpoint]
    local request = rt:_operation(function()
        if previous then
            previous:await()
        end
        if not registered then
            return nil, registration_error
        end
        if invalid then
            return nil, invalid
        end
        if not generation then
            return nil, ref
        end
        if kind == "window" and (not ref or ref.kind ~= "session") then
            return nil, failure("invalid_target", "window lookup requires a session")
        end
        if kind == "pane" and (not ref or (ref.kind ~= "pane" and ref.kind ~= "window")) then
            return nil, failure("invalid_target", "pane lookup requires a pane or window")
        end
        local argv = {
            "list-" .. kind .. "s",
            "-F",
            assert(
                codec.format({ kind .. "_id", kind == "pane" and pane_option or kind .. "_name" })
            ),
        }
        if ref then
            argv[#argv + 1], argv[#argv + 2] = "-t", ref.id
        end
        local result, err =
            state.bound:execute(argv, { timeout = 750, max_output_bytes = 1048576 }):await()
        if not result then
            return nil, err
        end
        local rows
        rows, err = codec.decode(result.stdout, 2, { max_rows = 16384, max_bytes = 1048576 })
        if not rows then
            return nil, err
        end
        local selected, first
        for _, row in ipairs(rows) do
            if not row[1]:match("^%" .. prefixes[kind] .. "[0-9]+$") then
                return nil, failure("invalid_receipt", "lookup returned a malformed object ID")
            end
            first = first or row[1]
            if row[2] == key then
                if selected then
                    return nil,
                        failure("ambiguous", "more than one object matches the exact lookup key")
                end
                selected = row[1]
            end
        end
        if selected then
            local value
            value, err = wrap(state, { kind = kind, id = selected, generation = generation })
            if not value then
                return nil, err
            end
            return { value = value, created = false }
        end
        local creation_parent = parent
        if kind == "pane" and ref and ref.kind == "window" then
            if not first then
                return nil, failure("target_missing", "window has no pane to split")
            end
            creation_parent, err =
                identity.bind(generation, { kind = "pane", id = first, generation = generation })
            if not creation_parent then
                return nil, err
            end
        end
        local owner
        owner, err = M.create(state, creation_parent, kind, copied, wrap):await()
        if not owner then
            return nil, err
        end
        if kind == "pane" then
            local receipt = owners[owner].receipt
            local configured
            configured, err = state.bound
                :execute(
                    guarded(receipt, {
                        { "set-option", "-p", "-t", receipt.id, pane_option, key },
                    }),
                    { timeout = 750 }
                )
                :await()
            if not configured or configured.stdout ~= "" then
                return nil,
                    err or failure(
                        "stale_generation",
                        "pane identity changed while assigning its key"
                    )
            end
        end
        -- Move automatic cleanup from this finite lookup task to its caller.
        holder.owner = M.transfer(owner)
        return { value = holder.owner.value, created = true, owner = holder.owner }
    end, { operation = "find_or_create_" .. kind, effect = "not_sent" })
    bucket[endpoint] = request
    request:_on_retire(function()
        if bucket[endpoint] == request then
            bucket[endpoint] = nil
        end
    end)
    return request
end

M.parse, M.nonce = parse, nonce

---@class libtmux.Owned<T>
---@field value T Accepted object; its client connection remains borrowed.
---@field closed boolean True only after successful cleanup.
---@field cleanup_error? libtmux.Error Last failed cleanup attempt.
---@field close fun(self:libtmux.Owned<T>):libtmux.Request<boolean>
--- Retryable destruction of the accepted generation.
---@field release fun(self:libtmux.Owned<T>):T?,libtmux.Error?
--- Relinquish destruction responsibility.
---@field receipt fun(self:libtmux.Owned<T>):table Copy of the accepted daemon and object identity.
---@field scope fun(self:libtmux.Owned<T>,
--- body:fun(value:T,owner:libtmux.Owned<T>):any):libtmux.Request<any>

---@class libtmux.FoundOrCreated<T>
---@field value T
---@field created boolean
---@field owner? libtmux.Owned<T> Present only for this call's new object.

return M
