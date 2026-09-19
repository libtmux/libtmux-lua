local M = {}

function M.new()
    local driver = { time = 0, ready = {}, timers = {} }
    function driver.now()
        return driver.time
    end
    function driver.defer(fn)
        driver.ready[#driver.ready + 1] = fn
    end
    function driver.timer(delay, fn)
        local timer = { at = driver.time + delay, fn = fn }
        driver.timers[#driver.timers + 1] = timer
        return function()
            timer.cancelled = true
        end
    end
    function driver:step()
        local fn = table.remove(self.ready, 1)
        if fn then
            fn()
            return true
        end
        return false
    end
    function driver:drain()
        local count = 0
        while self:step() do
            count = count + 1
            assert(count < 1000, "driver did not quiesce")
        end
    end
    function driver:advance(ms)
        self.time = self.time + ms
        local remaining = {}
        for _, timer in ipairs(self.timers) do
            if not timer.cancelled and timer.at <= self.time then
                self.defer(timer.fn)
            elseif not timer.cancelled then
                remaining[#remaining + 1] = timer
            end
        end
        self.timers = remaining
        self:drain()
    end
    return driver
end

---@class libtmux.TestDriver
---@field now fun():number
---@field timer fun(delay:number, callback:fun()):fun()
---@field pending integer

--- Private adapter probes retain access without expanding the public runtime type.
---@class libtmux.TestRuntime: libtmux.Runtime
---@field _driver libtmux.TestDriver
---@field _request fun(self:libtmux.TestRuntime, spec:table):libtmux.Request<unknown>

return M
