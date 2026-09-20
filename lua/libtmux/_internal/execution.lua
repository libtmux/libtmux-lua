local composition = require("libtmux._internal.batch")
local errors = require("libtmux._internal.error")
local process = require("libtmux._internal.process")
local MAX_INPUT_BYTES, MAX_TIMER_DELAY = 16 * 1024 * 1024, 2147483647
local M = {}

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function failure(code, message, cause)
    return errors.new(code, message, { operation = "command", effect = "not_sent", cause = cause })
end

local function rejected(runtime, err)
    return runtime:_operation(function()
        return nil, err
    end, { operation = "command", effect = "not_sent" })
end

local function length(value, maximum, empty)
    if not plain(value) then
        return nil
    end
    local count = 0
    for key in next, value do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key > maximum or key % 1 ~= 0 or count > maximum then
            return nil
        end
    end
    if count == 0 and not empty then
        return nil
    end
    for index = 1, count do
        if rawget(value, index) == nil then
            return nil
        end
    end
    return count
end

local function prepare(runtime, commands, options, empty)
    local count = length(commands, 1024, empty)
    if not count then
        return nil, failure("invalid_command", "commands must be a bounded dense sequence")
    end
    if options ~= nil and not plain(options) then
        return nil, failure("invalid_options", "process options must be a plain table")
    end
    if options and options.env ~= nil and not length(options.env, 4096, true) then
        return nil, failure("invalid_options", "process environment must be a bounded sequence")
    end
    local configured, err = process.prepare({ "tmux" }, options)
    if not configured then
        return nil, err
    end
    local opts, deadline = configured.options, configured.options.deadline
    local now = runtime._driver.now()
    if opts.timeout ~= nil then
        if
            type(opts.timeout) ~= "number"
            or opts.timeout ~= opts.timeout
            or opts.timeout < 0
            or opts.timeout > MAX_TIMER_DELAY
        then
            return nil, failure("invalid_options", "process timeout exceeds its portable range")
        end
        deadline = now + opts.timeout
    end
    if
        deadline ~= nil
        and (
            type(deadline) ~= "number"
            or deadline ~= deadline
            or math.abs(deadline) == math.huge
            or deadline - now > MAX_TIMER_DELAY
        )
    then
        return nil, failure("invalid_options", "process deadline exceeds its portable range")
    end
    local copied, argc, bytes = {}, 0, configured.bytes - #"tmux"
    for index = 1, count do
        local argv = rawget(commands, index)
        local size = length(argv, 4096, false)
        if not size or argc + size > 4096 then
            return nil, failure("invalid_command", "commands exceed the argument count limit")
        end
        local prepared
        prepared, err = process.prepare(argv)
        if not prepared then
            return nil, failure("invalid_command", "command argv is invalid", err)
        end
        argc, bytes = argc + size, bytes + prepared.bytes
        if bytes > MAX_INPUT_BYTES then
            return nil, failure("invalid_command", "commands exceed the input byte limit")
        end
        copied[index] = prepared.argv
    end
    if bytes > MAX_INPUT_BYTES then
        return nil, failure("invalid_options", "process input exceeds the byte limit")
    end
    return copied, opts, count > 0 and bytes or 0
end

M.prepare = prepare

function M.command(runtime, bound, argv, options)
    local commands, copied = prepare(runtime, { argv }, options, false)
    if not commands then
        return rejected(runtime, copied)
    end
    return bound:group(commands, copied)
end

function M.group(runtime, bound, commands, options)
    local copied, opts = prepare(runtime, commands, options, false)
    if not copied then
        return rejected(runtime, opts)
    end
    return bound:group(copied, opts)
end

function M.batch(runtime, bound, commands, options)
    if options ~= nil and not plain(options) then
        return rejected(runtime, failure("invalid_options", "batch options must be a plain table"))
    end
    options = options or {}
    for key in next, options do
        if key ~= "process" and key ~= "concurrency" then
            return rejected(runtime, failure("invalid_options", "unknown batch option"))
        end
    end
    local concurrency = options.concurrency == nil and 1 or options.concurrency
    if
        type(concurrency) ~= "number"
        or concurrency < 1
        or concurrency > 128
        or concurrency % 1 ~= 0
    then
        return rejected(runtime, failure("invalid_options", "batch concurrency must be 1..128"))
    end
    local copied, opts, bytes = prepare(runtime, commands, options.process, true)
    if not copied then
        return rejected(runtime, opts)
    end
    local tasks = {}
    local request
    for index, argv in ipairs(copied) do
        tasks[index] = {
            run = function()
                local result, err = bound:execute(argv, opts):await()
                return process.retain_output(request, result, err, "batch")
            end,
        }
    end
    request = composition.batch(runtime, tasks, { concurrency = concurrency })
    if not request:is_settled() then
        local retained, cause = request:_retain(bytes)
        if not retained then
            request:cancel(failure("queue_full", "batch input byte limit reached", cause))
        end
    end
    return request
end

return M
