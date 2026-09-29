local runtime = require("libtmux._internal.runtime")
local errors = require("libtmux._internal.error")
local M = {}

-- Host-neutral driver shared by the luv and Neovim adapters; it never imports luv.
-- The driver owns its timers and dispatches; uv itself always remains borrowed.
function M.new(uv, schedule)
    local driver = { uv = uv, pending = 0 }
    local idle = {}
    local function notify_idle()
        if driver.pending == 0 and #idle > 0 then
            local callbacks = idle
            idle = {}
            for _, callback in ipairs(callbacks) do
                driver.defer(callback)
            end
        end
    end
    local function deliver(fn)
        if schedule then
            driver.pending = driver.pending + 1
            local ok, err = pcall(schedule, function()
                driver.pending = driver.pending - 1
                fn()
                notify_idle()
            end)
            if not ok then
                driver.pending = driver.pending - 1
                error(errors.wrap(err, "host_error"), 0)
            end
        else
            fn()
            notify_idle()
        end
    end
    function driver.now()
        return uv.hrtime() / 1000000
    end
    function driver.timer(delay, fn)
        if
            type(delay) ~= "number"
            or delay ~= delay
            or delay < 0
            or delay > runtime.MAX_TIMER_DELAY
        then
            error(errors.new("invalid_timer", "timer delay exceeds the portable host limit"), 2)
        end
        local created, handle, cause = pcall(uv.new_timer)
        if not created or not handle then
            error(errors.wrap(created and cause or handle, "host_error"), 2)
        end
        driver.pending = driver.pending + 1
        local cancelled, closing = false, false
        local function close(fired)
            if closing then
                return
            end
            closing = true
            handle:stop()
            handle:close(function()
                driver.pending = driver.pending - 1
                if fired and not cancelled then
                    deliver(function()
                        if not cancelled then
                            fn()
                        end
                    end)
                else
                    notify_idle()
                end
            end)
        end
        local started, result, message = pcall(handle.start, handle, math.ceil(delay), 0, function()
            close(true)
        end)
        if not started or result == nil then
            cancelled = true
            close(false)
            error(errors.wrap(started and message or result, "host_error"), 2)
        end
        return function()
            cancelled = true
            close(false)
        end
    end
    function driver.defer(fn)
        if schedule then
            deliver(fn)
        else
            driver.timer(0, fn)
        end
    end
    function driver.after_idle(fn)
        idle[#idle + 1] = fn
        notify_idle()
    end
    return driver
end

function M.result(root, rt)
    local value, err = root:result()
    local cleanup = rt:errors()
    if not err and #cleanup > 0 then
        return nil, errors.new("cleanup_failed", "runtime cleanup failed", { errors = cleanup })
    end
    return value, err
end

return M
