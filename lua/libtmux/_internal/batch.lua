local errors = require("libtmux._internal.error")
local M = {}
local effects = { not_sent = true, unknown = true, completed = true }

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function integer(value, maximum)
    return type(value) == "number" and value >= 1 and value <= maximum and value % 1 == 0
end

local function failure(code, message, operation, partial)
    return errors.new(code, message, {
        operation = operation,
        effect = "not_sent",
        partial = partial,
    })
end

local function validate(tasks, options, sequence)
    if not plain(tasks) or (options ~= nil and not plain(options)) then
        return nil, "tasks and options must be plain tables"
    end
    options = options or {}
    for name in next, options do
        if name ~= "concurrency" then
            return nil, "unknown composition option"
        end
    end
    local concurrency = options.concurrency == nil and 1 or options.concurrency
    if not integer(concurrency, 128) or (sequence and concurrency ~= 1) then
        return nil, "batch concurrency must be 1..128; sequence concurrency must be 1"
    end
    local count = 0
    for index in next, tasks do
        count = count + 1
        if count > 1024 or not integer(index, 1024) then
            return nil, "tasks must be a dense sequence of at most 1024 entries"
        end
    end
    local copied = {}
    for index = 1, count do
        local task = rawget(tasks, index)
        if not plain(task) or type(rawget(task, "run")) ~= "function" then
            return nil, "every task must be a plain record with a run function"
        end
        for key in next, task do
            if key ~= "run" then
                return nil, "unknown task field"
            end
        end
        copied[index] = task.run
    end
    return copied, concurrency
end

local function receipt(outcomes, states, count)
    local result = {}
    for index = 1, count do
        local outcome = outcomes[index]
        if states and states[index] == "running" then
            result[index] = { status = "unknown", effect = "unknown" }
        else
            result[index] = {
                status = outcome.status,
                value = outcome.value,
                error = outcome.error,
                effect = outcome.effect,
            }
        end
    end
    return result
end

local function compose(runtime, tasks, options, sequence)
    local operation = sequence and "sequence" or "batch"
    local copied, concurrency = validate(tasks, options, sequence)
    if not copied then
        return runtime:_operation(function()
            return nil, failure("invalid_batch", concurrency, operation)
        end, { operation = operation, effect = "not_sent" })
    end
    ---@cast concurrency integer
    local outcomes, states = {}, {}
    for index = 1, #copied do
        outcomes[index] = { status = "skipped", effect = "not_sent" }
        states[index] = "pending"
    end
    local context = {
        operation = operation,
        effect = "not_sent",
        partial = { outcomes = receipt(outcomes, states, #copied) },
    }
    return runtime:_operation(function(rt, parent)
        if #copied == 0 then
            return outcomes
        end
        local capacity = rt:stats()
        local slots = math.min(concurrency, capacity.max_tasks - capacity.tasks, #copied)
        if slots < 1 then
            return nil,
                failure(
                    "queue_full",
                    "composition has no available task slot",
                    operation,
                    context.partial
                )
        end
        local next_index, stopped = 1, false
        local function publish()
            local effect = "not_sent"
            for index, outcome in ipairs(outcomes) do
                if states[index] == "running" or outcome.effect == "unknown" then
                    effect = "unknown"
                    break
                elseif outcome.effect == "completed" then
                    effect = "completed"
                end
            end
            parent:_set_effect(effect)
            -- Envelope snapshots never change after publication. Returned task
            -- values and errors remain caller-owned references, as with Request.
            parent:_set_partial({ outcomes = receipt(outcomes, states, #copied) })
        end
        local launch
        launch = function(index)
            local child = rt:_operation(function(inner)
                states[index] = "running"
                publish()
                local previous = sequence and receipt(outcomes, nil, index - 1) or nil
                return copied[index](inner, previous)
            end, { operation = operation .. ".item", effect = "not_sent" })
            child:_on_retire(function()
                if parent:is_settled() then
                    return
                end
                local value, err = child:result()
                if err then
                    local effect = type(err) == "table" and rawget(err, "effect") or nil
                    if not effects[effect] then
                        effect = states[index] == "running" and "unknown" or "not_sent"
                    end
                    outcomes[index] = {
                        status = effect == "unknown" and "unknown" or "failed",
                        error = err,
                        effect = effect,
                    }
                    stopped = stopped or sequence
                else
                    outcomes[index] = { status = "completed", value = value, effect = "completed" }
                end
                states[index] = "finished"
                publish()
                if stopped or next_index > #copied then
                    return
                end
                local following = next_index
                next_index = next_index + 1
                -- Keep admission deferred and scoped to this composition. Native
                -- retirement bookkeeping records the outcome before cancellation.
                local ok, cause = pcall(child.on_complete, child, function()
                    if parent:is_settled() or stopped then
                        return
                    end
                    launch(following)
                end)
                if not ok then
                    parent:cancel(cause)
                end
            end)
            publish()
        end
        for _ = 1, slots do
            local index = next_index
            next_index = next_index + 1
            launch(index)
        end
        return outcomes
    end, context)
end

function M.batch(runtime, tasks, options)
    return compose(runtime, tasks, options, false)
end

function M.sequence(runtime, tasks, options)
    return compose(runtime, tasks, options, true)
end

return M
