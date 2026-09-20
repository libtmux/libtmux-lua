local errors = require("libtmux._internal.error")
local execution = require("libtmux._internal.execution")
local identity = require("libtmux._internal.identity")
local process = require("libtmux._internal.process")
local text = require("libtmux._internal.text")
local M, Value = {}, {}
local MAX_BYTES, MAX_NAME = 1048576, 4096
local commands =
    { set = "load-buffer", show = "show-buffer", delete = "delete-buffer", paste = "paste-buffer" }
local versions = {
    ["3.2a"] = 2,
    ["3.3"] = 3,
    ["3.3a"] = 3,
    ["3.4"] = 4,
    ["3.5"] = 5,
    ["3.5a"] = 5,
    ["3.6"] = 6,
    ["3.6a"] = 6,
    ["3.6b"] = 6,
    ["3.7"] = 7,
    ["3.7a"] = 7,
    ["3.7b"] = 7,
    ["3.7c"] = 7,
}
local paste_fields = {
    bytes = true,
    linefeed_separator = true,
    separator = true,
    bracket = true,
    delete_after = true,
}
local process_fields = {
    timeout = true,
    deadline = true,
    max_output_bytes = true,
    drain_timeout = true,
    kill_timeout = true,
}

local function failure(code, message, kind, ref, effect, details)
    details = details or {}
    details.operation = "buffer." .. (type(kind) == "string" and kind or "invalid")
    details.effect, details.target = effect or "not_sent", ref
    return errors.new(code, message, details)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

function Value:text()
    if not text.valid_utf8(self.bytes) then
        return nil,
            failure("invalid_utf8", "buffer contains invalid UTF-8", "show", nil, "completed")
    end
    return self.bytes
end

local function current(state, owned, kind)
    if state.closed then
        return nil, failure("closed", "server handle is closed", kind)
    end
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    if kind ~= "paste" then
        if owned ~= nil then
            return nil, failure("invalid_target", "buffer operation requires a Server", kind)
        end
        return { kind = "server", generation = generation }
    end
    if owned == nil then
        return nil, failure("invalid_target", "buffer paste requires a Pane", kind)
    end
    local ref
    ref, err = identity.inspect(generation, owned)
    if not ref then
        return nil, err
    end
    if ref.kind ~= "pane" then
        return nil, failure("invalid_target", "buffer paste requires a Pane", kind, ref)
    end
    return ref
end

local function prepare(state, ref, kind, name, bytes, options)
    local function invalid(code, message)
        error(failure(code, message, kind, ref), 0)
    end
    local version = type(state.version) == "string" and versions[state.version]
    if not version then
        invalid("unsupported_version", "buffer operations require a supported exact tmux release")
    end
    if type(name) ~= "string" or #name == 0 or #name > MAX_NAME or name:find("\000", 1, true) then
        invalid(
            kind == "set" and "unsupported_name" or "invalid_argument",
            "buffer name must be nonempty bounded NUL-free bytes"
        )
    end
    if kind == "set" then
        if not text.valid_utf8(name) or name:find("[\001-\031\127\\]") then
            invalid(
                "unsupported_name",
                "buffer creation name requires UTF-8 without controls or backslashes"
            )
        end
        if type(bytes) ~= "string" or #bytes == 0 or #bytes > MAX_BYTES then
            invalid(
                "invalid_argument",
                "buffer value must contain from one byte to one MiB; empty native writes are no-ops"
            )
        end
    elseif bytes ~= nil then
        invalid("invalid_argument", "only buffer set accepts a value")
    end
    if kind == "delete" and version < 4 then
        invalid(
            "unsupported",
            "named buffer deletion requires tmux 3.4+; older releases can delete another buffer"
        )
    end
    if options ~= nil and not plain(options) then
        invalid("invalid_options", "buffer options must be a plain record")
    end
    options = options or {}
    for key in next, options do
        if key ~= "process" and not (kind == "paste" and paste_fields[key]) then
            invalid("invalid_options", "unknown buffer option")
        end
    end
    local argv = { commands[kind], "-b", name }
    if kind == "set" then
        argv[#argv + 1] = "-"
    elseif kind == "paste" then
        argv[#argv + 1], argv[#argv + 2] = "-t", ref.id
        if options.bytes ~= nil and options.bytes ~= "native" and options.bytes ~= "raw" then
            invalid("invalid_options", "paste byte mode must be native or raw")
        end
        if options.bytes == "raw" and version >= 7 then
            argv[#argv + 1] = "-S"
        end
        for _, item in ipairs({
            { "linefeed_separator", "-r" },
            { "bracket", "-p" },
            { "delete_after", "-d" },
        }) do
            local value = options[item[1]]
            if value ~= nil and type(value) ~= "boolean" then
                invalid("invalid_options", "paste switches must be booleans")
            end
            if value then
                argv[#argv + 1] = item[2]
            end
        end
        if options.separator ~= nil then
            if options.linefeed_separator ~= nil then
                invalid("invalid_options", "paste separator excludes linefeed_separator")
            end
            if
                type(options.separator) ~= "string"
                or #options.separator > 4096
                or options.separator:find("\000", 1, true)
            then
                invalid("invalid_options", "paste separator must be bounded NUL-free bytes")
            end
            argv[#argv + 1], argv[#argv + 2] = "-s", options.separator
        end
    end
    local configured = { max_output_bytes = MAX_BYTES }
    if options.process ~= nil then
        if not plain(options.process) then
            invalid("invalid_options", "process options must be a plain record")
        end
        for key, value in next, options.process do
            if not process_fields[key] then
                invalid("invalid_options", "unsupported buffer process option")
            end
            configured[key] = value
        end
        if
            type(configured.max_output_bytes) ~= "number"
            or configured.max_output_bytes > MAX_BYTES
        then
            invalid("invalid_options", "buffer output limit must not exceed one MiB")
        end
    end
    if kind == "set" then
        configured.stdin = bytes
    end
    local copied, opts, cost = execution.prepare(state.runtime, { argv }, configured, false)
    if not copied then
        error(opts, 0)
    end
    return { argv = copied[1], options = opts, bytes = cost, name = name }
end

function M.run(state, owned, kind, name, bytes, options)
    local ref, err, plan
    if type(kind) ~= "string" or not commands[kind] then
        err = failure("invalid_operation", "unknown buffer operation", kind)
    else
        ref, err = current(state, owned, kind)
        if ref then
            local ok, value = pcall(prepare, state, ref, kind, name, bytes, options)
            if ok then
                plan = value
            else
                err = value
            end
        end
    end
    local request = state.runtime:_operation(function(_, active)
        if not plan or not ref then
            return nil, err
        end
        local now, invalid = current(state, owned, kind)
        if not now then
            return nil, invalid
        end
        if not rawequal(ref.generation, now.generation) then
            return nil,
                failure(
                    "stale_generation",
                    "server generation changed before buffer operation",
                    kind,
                    ref
                )
        end
        active:_set_effect("unknown")
        local result, cause = state.bound:execute(plan.argv, plan.options):await()
        result, cause = process.retain_output(active, result, cause, "buffer." .. kind)
        if not result then
            return nil, cause
        end
        active:_set_effect("completed")
        now, invalid = current(state, owned, kind)
        if not now or not rawequal(ref.generation, now.generation) then
            return nil,
                failure(
                    invalid and invalid.code or "stale_generation",
                    invalid and invalid.message
                        or "server generation changed after buffer operation",
                    kind,
                    ref,
                    "completed",
                    { cause = invalid, partial = result }
                )
        end
        if kind == "show" then
            return setmetatable({ name = plan.name, bytes = result.stdout }, { __index = Value })
        end
        return true
    end, {
        operation = "buffer." .. (type(kind) == "string" and kind or "invalid"),
        effect = "not_sent",
        target = ref,
    })
    if plan and not request:is_settled() then
        local accepted, cause = request:_retain(plan.bytes)
        if not accepted then
            request:cancel(
                failure(
                    "queue_full",
                    "buffer input exceeds runtime byte capacity",
                    kind,
                    ref,
                    nil,
                    { cause = cause }
                )
            )
        end
    end
    return request
end

---@class libtmux.BufferValue
---@field name string Explicit current buffer name; not an incarnation identifier.
---@field bytes string Exact buffer bytes, including NUL and trailing newlines.
---@field text fun(self:libtmux.BufferValue):string?,libtmux.Error?
--- Strict UTF-8 without normalization.

---@class libtmux.BufferOptions
---@field process? libtmux.CreationProcessOptions Output limit is at most one MiB.

---@class libtmux.PasteBufferOptions: libtmux.BufferOptions
---@field bytes? "native"|"raw" Native defaults follow the daemon; raw disables 3.7+ sanitization.
---@field linefeed_separator? boolean Preserve LF instead of native LF-to-CR conversion.
---@field separator? string Explicit NUL-free separator; excludes linefeed_separator.
---@field bracket? boolean Wrap only when native bracketed paste mode is enabled.
---@field delete_after? boolean Native deletion can succeed even when pane input is disabled.

return M
