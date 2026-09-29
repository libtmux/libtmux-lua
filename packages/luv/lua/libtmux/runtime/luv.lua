local runtime = require("libtmux._internal.runtime")
local driver_module = require("libtmux._internal.driver")
local errors = require("libtmux._internal.error")
local M = {}
local running = false

M._driver, M._result = driver_module.new, driver_module.result

---@generic T
---@param fn fun(runtime:libtmux.Runtime):T?, libtmux.Error?
---@param options? libtmux.RuntimeOptions
---@return T? value
---@return libtmux.Error? error
function M.run(fn, options)
    local co, is_main = coroutine.running()
    local host = rawget(_G, "vim")
    if running or (co and not is_main) or host then
        return nil, errors.new("invalid_run_context", "run needs a standalone top-level caller")
    end
    local loaded, uv = pcall(require, "luv")
    if not loaded then
        return nil,
            errors.new("unsupported_host", "standalone runtime requires the luv module", {
                cause = uv,
            })
    end
    if not debug or type(debug.getinfo) ~= "function" then
        return nil, errors.new("invalid_run_context", "run cannot verify the standalone call stack")
    end
    local depth = 2
    while depth <= 128 do
        local frame = debug.getinfo(depth, "f")
        if not frame then
            break
        end
        if frame.func == uv.run then
            return nil, errors.new("invalid_run_context", "run cannot reenter a running host loop")
        end
        depth = depth + 1
    end
    if depth > 128 then
        return nil, errors.new("invalid_run_context", "run cannot verify the standalone call stack")
    end
    if uv.loop_alive() then
        return nil, errors.new("invalid_run_context", "run needs a quiescent standalone loop")
    end
    local driver = driver_module.new(uv)
    local rt = runtime.new(driver, options)
    local root = rt:start(fn)
    local failure, guard, expired, guard_failed
    local host_failures, cleanup_turns = 0, 0
    local function incomplete()
        if guard then
            local ok, err = pcall(guard)
            guard = nil
            if not ok then
                rt:_record(errors.wrap(err, "cleanup_failed"))
            end
        end
        -- A broken host can prevent cleanup itself; report remaining ownership.
        pcall(uv.run, "nowait")
        local _, original = root:result()
        return nil,
            errors.new("cleanup_failed", "owned runtime resources did not retire", {
                cause = original or failure,
                resources = rt:stats(),
                errors = rt:errors(),
                driver_pending = driver.pending,
            })
    end
    local function fail(err)
        failure = err
        if root._scope then
            local ok, cause = pcall(rt._abort, rt, root._scope, err)
            if not ok then
                rt:_record(errors.wrap(cause, "cleanup_failed"))
            end
        end
        local ok, cancel = pcall(driver.timer, 1000, function()
            expired = true
        end)
        if ok then
            guard = cancel
        else
            guard_failed = true
            rt:_record(errors.wrap(cancel, "cleanup_failed"))
        end
    end
    local function drive()
        while not root:is_retired() or driver.pending > 0 do
            if guard and root:is_retired() and driver.pending == 1 then
                guard()
                guard = nil
            end
            if expired or host_failures >= 16 or (guard_failed and cleanup_turns >= 64) then
                return incomplete()
            end
            if not uv.loop_alive() then
                if failure then
                    return incomplete()
                end
                fail(errors.new("runtime_stalled", "unfinished runtime has no active event source"))
            end
            local ok, err = pcall(uv.run, guard_failed and "nowait" or "once")
            cleanup_turns = cleanup_turns + 1
            if not ok then
                host_failures = host_failures + 1
                if not failure then
                    fail(errors.wrap(err, "host_error"))
                else
                    rt:_record(errors.wrap(err, "host_error"))
                end
            end
        end
        local value, err = driver_module.result(root, rt)
        if failure and not err then
            return nil, failure
        end
        return value, err
    end
    running = true
    -- This protects loop driving; yielding task bodies run in separate coroutines.
    local ok, value, err = pcall(drive)
    if not ok then
        local thrown = value
        local recovered
        recovered, value, err = pcall(function()
            failure = errors.wrap(thrown, "host_error")
            if root._scope then
                pcall(rt._abort, rt, root._scope, failure)
            end
            return incomplete()
        end)
        running = false
        if not recovered then
            return nil,
                errors.new("cleanup_failed", "host failure prevented runtime cleanup", {
                    cause = thrown,
                    cleanup_error = value,
                    resources = rt:stats(),
                    driver_pending = driver.pending,
                })
        end
        return value, err
    end
    running = false
    return value, err
end

return M
