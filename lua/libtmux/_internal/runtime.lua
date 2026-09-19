local errors = require("libtmux._internal.error")
local M, Runtime, Request, Lease, Budget = { MAX_TIMER_DELAY = 2147483647 }, {}, {}, {}, {}
Runtime.__index, Request.__index, Lease.__index = Runtime, Request, Lease
Budget.__index = Budget
local managed = setmetatable({}, { __mode = "k" })
local WAIT = {}

local function copy(value)
    local result = {}
    for key, item in pairs(value) do
        result[key] = item
    end
    return result
end

local function context_copy(value)
    local result = copy(value)
    if type(result.partial) == "table" then
        result.partial = copy(result.partial)
    end
    return result
end

local function cleanup_error(cause)
    return errors.new("cleanup_failed", "owned runtime cleanup failed", { cause = cause })
end

local function remove(list, value)
    for i = #list, 1, -1 do
        if list[i] == value then
            table.remove(list, i)
            return
        end
    end
end

local function release_delivery(scope)
    local req = scope.delivery
    if req then
        scope.delivery = nil
        req._delivery_count = req._delivery_count - 1
        req:_release_bytes()
    end
end

local function integer(value, minimum)
    return type(value) == "number" and value >= minimum and value < math.huge and value % 1 == 0
end

local function request(rt, owner)
    local req = setmetatable({
        _runtime = rt,
        _owner = owner,
        _callbacks = {},
        _waiters = {},
        _callback_count = 0,
        _delivery_count = 0,
        _bytes = 0,
        _cost = 0,
    }, Request)
    if owner then
        owner.owned[#owner.owned + 1] = req
    end
    return req
end

function M.new(driver, options)
    options = options or {}
    for _, key in ipairs({ "defer", "now", "timer" }) do
        if type(driver[key]) ~= "function" then
            error(errors.new("invalid_driver", "runtime driver needs " .. key), 2)
        end
    end
    local limits = {
        max_active = 16,
        max_pending = 128,
        max_logical = 128,
        max_bytes = 16 * 1024 * 1024,
        max_tasks = 128,
        max_callbacks = 256,
        max_resources = 128,
        dispatch_budget = 64,
    }
    for key, value in pairs(options) do
        if limits[key] == nil or not integer(value, key == "max_pending" and 0 or 1) then
            error(errors.new("invalid_options", "invalid runtime limit: " .. tostring(key)), 2)
        end
        limits[key] = value
    end
    return setmetatable({
        _driver = driver,
        _limits = limits,
        _queue = {},
        _pending = {},
        _active = 0,
        _logical = 0,
        _bytes = 0,
        _resource_bytes = 0,
        _tasks = 0,
        _callbacks = 0,
        _resources = {},
        _resources_closing = 0,
        _resources_failed = 0,
        _errors = {},
        _rejected = 0,
        _submitted = 0,
    }, Runtime)
end

function Runtime:_schedule()
    if self._scheduled or self._dispatch_error or #self._queue == 0 then
        return
    end
    self._scheduled = true
    self._driver.defer(function()
        self._scheduled = false
        local count = math.min(#self._queue, self._limits.dispatch_budget)
        for _ = 1, count do
            local work = table.remove(self._queue, 1)
            if not work then
                break
            end
            work.fn()
        end
        local ok, err = pcall(self._schedule, self)
        if not ok then
            self:_dispatch_failure(err)
        end
    end)
end

function Runtime:_dispatch_failure(cause)
    if self._dispatch_error then
        return
    end
    local err = errors.wrap(cause, "host_error")
    -- Failed host scheduling closes this runtime; user callbacks cannot run inline.
    self._dispatch_error, self._closing, self._scheduled = err, true, false
    local queue = self._queue
    self._queue = {}
    if self._root_scope then
        self:_fail(self._root_scope, err)
    else
        self:_record(err)
    end
    for _, work in ipairs(queue) do
        if work.reject then
            work.reject()
        end
    end
end

function Runtime:_enqueue(fn, reject)
    if self._dispatch_error then
        error(self._dispatch_error, 0)
    end
    local work = { fn = fn, reject = reject }
    self._queue[#self._queue + 1] = work
    local ok, err = pcall(self._schedule, self)
    if not ok then
        self:_dispatch_failure(err)
        error(self._dispatch_error, 0)
    end
    return work
end

function Runtime:_cancel_work(work)
    if work then
        remove(self._queue, work)
    end
end

function Runtime:_record(err)
    if #self._errors < 16 then
        self._errors[#self._errors + 1] = err
    end
end

function Runtime:_owner()
    local co = coroutine.running()
    local scope = co and managed[co] or self._callback_scope
    if scope and scope.runtime ~= self then
        return nil
    end
    scope = scope or self._root_scope
    if self._closing or not scope or scope.finished or scope.error then
        return nil
    end
    return scope
end

function Runtime:_rejected_request(code, message)
    self._rejected = self._rejected + 1
    local req = request(self)
    req:_settle(nil, errors.new(code, message))
    req:_retire()
    return req
end

function Request:is_settled()
    return self._settled == true
end

function Request:is_retired()
    return self._retired == true
end

function Request:_notify_retired()
    local hook = self._retire_hook
    self._retire_hook = nil
    if hook then
        local ok, err = pcall(hook)
        if not ok then
            self._runtime:_record(cleanup_error(err))
        end
    end
end

-- Internal bookkeeping only: it must not yield or invoke user callbacks.
function Request:_on_retire(fn)
    if type(fn) ~= "function" or self._retire_hook_registered then
        error(errors.new("invalid_callback", "request permits one retirement hook"), 2)
    end
    self._retire_hook_registered, self._retire_hook = true, fn
    if self._retired then
        self:_notify_retired()
    end
    return self
end

function Request:result()
    if not self._settled then
        return nil, errors.new("pending", "request has not settled")
    end
    return self._value, self._error
end

function Request:_release_bytes()
    if self._retired and self._callback_count == 0 and self._delivery_count == 0 then
        self._runtime._bytes = self._runtime._bytes - self._bytes
        self._bytes = 0
    end
end

function Request:_set_effect(effect)
    self._effect = effect
end

function Request:_set_partial(partial)
    self._partial = type(partial) == "table" and copy(partial) or partial
end

function Request:_retain(bytes)
    if not integer(bytes, 0) then
        error(errors.new("invalid_options", "retained bytes must be a nonnegative integer"), 2)
    end
    if self._retired then
        return false, errors.new("closed", "request transport has retired")
    end
    local rt = self._runtime
    if rt._bytes + bytes > rt._limits.max_bytes then
        return false, errors.new("queue_full", "runtime retained byte limit reached")
    end
    rt._bytes, self._bytes, self._cost = rt._bytes + bytes, self._bytes + bytes, self._cost + bytes
    return true
end

function Request:_dispatch_callback(callback)
    local rt, scope = self._runtime, callback.scope
    -- Queue rejection can run before the failed enqueue returns its error.
    local finished = false
    local function finish(ok, err)
        if finished then
            return
        end
        finished = true
        self._callback_count = self._callback_count - 1
        rt._callbacks = rt._callbacks - 1
        if scope then
            scope.callbacks = scope.callbacks - 1
        end
        self:_release_bytes()
        if not ok then
            err = errors.wrap(err, "callback_error")
            if scope then
                rt:_fail(scope, err)
            else
                rt:_record(err)
            end
        end
        if scope then
            rt:_join(scope)
        end
    end
    local queued = pcall(rt._enqueue, rt, function()
        rt._callback_scope = scope
        local ok, err = pcall(callback.fn, self._value, self._error)
        rt._callback_scope = nil
        finish(ok, err)
    end, function()
        finish(true)
    end)
    if not queued then
        finish(true)
    end
end

function Request:on_complete(fn)
    if type(fn) ~= "function" then
        error(errors.new("invalid_callback", "completion callback must be a function"), 2)
    end
    local rt = self._runtime
    if rt._closing or (rt._root_scope and rt._root_scope.finished) then
        error(errors.new("closed", "runtime completion scope has closed"), 2)
    end
    local reserve = self._bytes == 0 and self._cost or 0
    if rt._callbacks >= rt._limits.max_callbacks or rt._bytes + reserve > rt._limits.max_bytes then
        error(errors.new("queue_full", "runtime completion callback limit reached"), 2)
    end
    local scope = self._owner
    if not scope or scope.finished then
        scope = rt:_owner()
    end
    if scope == self._scope then
        scope = nil
    end
    rt._bytes, self._bytes = rt._bytes + reserve, self._bytes + reserve
    rt._callbacks, self._callback_count = rt._callbacks + 1, self._callback_count + 1
    if scope then
        scope.callbacks = scope.callbacks + 1
    end
    local callback = { fn = fn, scope = scope }
    if self._settled then
        self:_dispatch_callback(callback)
    else
        self._callbacks[#self._callbacks + 1] = callback
    end
    return self
end

function Request:_settle(value, err)
    if self._settled then
        return false
    end
    self._settled, self._value, self._error = true, value, err
    if self._cancel_timer then
        local ok, cause = pcall(self._cancel_timer)
        self._cancel_timer = nil
        if not ok then
            self._runtime:_record(errors.wrap(cause, "cleanup_failed"))
        end
    end
    local waiters = self._waiters
    self._waiters = {}
    for _, scope in ipairs(waiters) do
        if scope.waiting == self and not scope.error then
            scope.waiting = nil
            scope.delivery = self
            self._delivery_count = self._delivery_count + 1
            local ok, work = pcall(self._runtime._enqueue, self._runtime, function()
                self._runtime:_resume(scope, value, err)
            end)
            if ok then
                scope.work = work
            else
                release_delivery(scope)
                self._runtime:_fail(scope, errors.wrap(work, "host_error"))
            end
        end
    end
    for _, callback in ipairs(self._callbacks) do
        self:_dispatch_callback(callback)
    end
    self._callbacks = {}
    return true
end

function Request:_retire(err)
    if self._retired then
        return
    end
    local rt = self._runtime
    self._retired = true
    rt:_cancel_work(self._work)
    self._work = nil
    self._spec, self._cancel_hook = nil, nil
    if err then
        rt:_record(errors.wrap(err, "cleanup_failed"))
    end
    if self._logical then
        rt._logical = rt._logical - 1
    elseif self._admitted then
        rt._active = rt._active - 1
    elseif self._queued then
        remove(rt._pending, self)
    end
    self:_release_bytes()
    self:_notify_retired()
    if self._owner then
        remove(self._owner.owned, self)
        rt:_join(self._owner)
    end
    rt:_admit()
end

function Request:_stop(err)
    if self._retired or self._stopping then
        return
    end
    self._stopping = err
    if not self._started then
        self:_retire()
    elseif self._cancel_hook then
        local ok, cause = pcall(self._cancel_hook, err)
        if not ok then
            self._runtime:_record(errors.wrap(cause, "cleanup_failed"))
        end
    end
end

function Request:_cancel_error(reason)
    local err
    if type(reason) == "table" and reason.code then
        local fields = context_copy(reason)
        err = errors.new(reason.code, reason.message, fields)
    else
        err = errors.new("cancelled", type(reason) == "string" and reason or "request cancelled")
    end
    local context = self._context or self._spec
    if context then
        err.effect, err.operation, err.target = self._effect, context.operation, context.target
        if context.partial ~= nil then
            err.partial = type(context.partial) == "table" and copy(context.partial)
                or context.partial
        end
    end
    if self._partial ~= nil then
        err.partial = type(self._partial) == "table" and copy(self._partial) or self._partial
    end
    return err
end

function Request:cancel(reason)
    if self._settled or self._cleanup then
        return false
    end
    local err = self:_cancel_error(reason)
    if self._scope then
        self._runtime:_abort(self._scope, err)
    else
        self:_settle(nil, err)
        self:_stop(err)
    end
    return true
end

function Request:await()
    local co = coroutine.running()
    local scope = co and managed[co]
    if not scope or scope.runtime ~= self._runtime then
        error(
            errors.new("invalid_await_context", "await needs a managed task in the same runtime"),
            2
        )
    end
    if scope.error then
        return nil, scope.error
    end
    if self._settled then
        return self._value, self._error
    end
    scope.waiting = self
    self._waiters[#self._waiters + 1] = scope
    return coroutine.yield(WAIT)
end

function Runtime:_start_request(req)
    local ok, work = pcall(self._enqueue, self, function()
        req._work = nil
        if req._retired then
            return
        end
        req._started = true
        local started, hook = pcall(req._spec.start, function(value, err)
            req:_settle(value, err)
        end, function(err)
            if not req._settled then
                req:_settle(
                    nil,
                    errors.new("transport_error", "transport retired without a result")
                )
            end
            req:_retire(err)
        end, req)
        if not started then
            req:_settle(nil, errors.wrap(hook, "transport_error"))
            req:_retire()
        elseif not req._retired then
            req._cancel_hook = hook
            if req._stopping and hook then
                local stopped, err = pcall(hook, req._stopping)
                if not stopped then
                    self:_record(errors.wrap(err, "cleanup_failed"))
                end
            end
        end
    end)
    if ok then
        req._work = work
    else
        req:_settle(nil, errors.wrap(work, "host_error"))
        req:_retire()
    end
end

function Runtime:_admit()
    if self._closing then
        return
    end
    while self._active < self._limits.max_active and #self._pending > 0 do
        local req = table.remove(self._pending, 1)
        if not req._retired then
            req._queued, req._admitted = false, true
            self._active = self._active + 1
            self:_start_request(req)
        end
    end
end

function Runtime:_submit(spec, logical)
    local owner = self:_owner()
    if not owner then
        return self:_rejected_request("closed", "runtime has no live submission scope")
    end
    if
        type(spec) ~= "table"
        or type(spec.start) ~= "function"
        or not integer(spec.bytes or 0, 0)
    then
        return self:_rejected_request(
            "invalid_request",
            "request needs a start function and nonnegative byte cost"
        )
    end
    local deadline = spec.deadline
    if spec.timeout ~= nil then
        if
            type(spec.timeout) ~= "number"
            or spec.timeout < 0
            or spec.timeout > M.MAX_TIMER_DELAY
        then
            return self:_rejected_request(
                "invalid_request",
                "request timeout must be finite and nonnegative"
            )
        end
        deadline = self._driver.now() + spec.timeout
    end
    if
        deadline ~= nil
        and (type(deadline) ~= "number" or deadline ~= deadline or math.abs(deadline) == math.huge)
    then
        return self:_rejected_request("invalid_request", "request deadline must be finite")
    end
    if deadline and deadline - self._driver.now() > M.MAX_TIMER_DELAY then
        return self:_rejected_request("invalid_request", "request deadline exceeds the timer limit")
    end
    local bytes = spec.bytes or 0
    local full = logical and self._logical >= self._limits.max_logical
        or not logical
            and self._active >= self._limits.max_active
            and #self._pending >= self._limits.max_pending
    if full or self._bytes + bytes > self._limits.max_bytes then
        return self:_rejected_request("queue_full", "runtime request admission limit reached")
    end
    self._submitted = self._submitted + 1
    local req = request(self, owner)
    req._spec, req._effect = spec, spec.effect
    req:_retain(bytes)
    if logical then
        req._logical = true
        self._logical = self._logical + 1
    else
        req._queued = true
        self._pending[#self._pending + 1] = req
    end
    if deadline then
        local remaining = deadline - self._driver.now()
        if remaining <= 0 then
            req:cancel(errors.new("deadline_exceeded", "request deadline expired"))
            return req
        end
        local ok, cancel = pcall(self._driver.timer, remaining, function()
            req:cancel(errors.new("deadline_exceeded", "request deadline expired"))
        end)
        if not ok then
            req:_settle(nil, errors.wrap(cancel, "host_error"))
            req:_retire()
            return req
        end
        req._cancel_timer = cancel
    end
    if logical then
        self:_start_request(req)
    else
        self:_admit()
    end
    return req
end

function Runtime:_request(spec)
    return self:_submit(spec, false)
end

function Runtime:_logical_request(spec)
    return self:_submit(spec, true)
end

function Runtime:_join(scope)
    if
        scope.finished
        or scope.joining
        or not scope.body_done
        or #scope.owned > 0
        or scope.callbacks > 0
    then
        return
    end
    if scope == self._root_scope then
        self._closing = true
        if #self._resources > 0 then
            scope.joining = true
            local resources = copy(self._resources)
            for _, lease in ipairs(resources) do
                lease:close()
            end
            scope.joining = false
            if #self._resources > 0 or #scope.owned > 0 then
                return
            end
        end
        if self._resource_error and not scope.error then
            scope.value, scope.error = nil, self._resource_error
        end
    end
    scope.finished = true
    managed[scope.co] = nil
    self._tasks = self._tasks - 1
    scope.request:_settle(scope.value, scope.error)
    scope.request:_retire()
    if scope == self._root_scope then
        self._closing = true
        if self._on_close then
            local ok, err = pcall(self._on_close)
            if not ok then
                self:_record(errors.wrap(err, "host_error"))
            end
        end
    end
end

function Runtime:_abort(scope, err)
    if scope.finished or scope.error then
        return
    end
    scope.error, scope.body_done = err, true
    self:_cancel_work(scope.work)
    scope.work = nil
    release_delivery(scope)
    if scope == self._root_scope then
        self._closing = true
    end
    if scope.waiting then
        remove(scope.waiting._waiters, scope)
        scope.waiting = nil
    end
    scope.request:_settle(nil, err)
    local owned = {}
    for i, req in ipairs(scope.owned) do
        owned[i] = req
    end
    for i = #owned, 1, -1 do
        if owned[i]._settled then
            if not owned[i]._scope then
                owned[i]:_stop(owned[i]:_cancel_error(err))
            end
        else
            owned[i]:cancel(err)
        end
    end
    self:_join(scope)
end

function Runtime:_fail(scope, err)
    while scope.request._owner and not scope.boundary do
        scope = scope.request._owner
    end
    if scope.finished or scope.error then
        if err ~= scope.error then
            self:_record(err)
        end
    else
        self:_abort(scope, err)
    end
end

function Runtime:_resume(scope, ...)
    scope.work = nil
    release_delivery(scope)
    if scope.body_done then
        return
    end
    -- coroutine.resume is the error boundary; Lua 5.1 cannot yield through pcall.
    local ok, value, err = coroutine.resume(scope.co, ...)
    if not ok then
        self:_fail(scope, errors.wrap(value, "task_error"))
    elseif coroutine.status(scope.co) == "dead" then
        if err then
            self:_fail(scope, err)
        else
            scope.body_done, scope.value = true, value
            self:_join(scope)
        end
    elseif value ~= WAIT then
        self:_fail(
            scope,
            errors.new("invalid_yield", "tasks may yield only through runtime operations")
        )
    end
end

function Runtime:_task(fn, owner, context, boundary)
    if type(fn) ~= "function" then
        return self:_rejected_request("invalid_task", "task body must be a function")
    end
    if self._tasks >= self._limits.max_tasks then
        return self:_rejected_request("queue_full", "runtime task limit reached")
    end
    local req = request(self, owner)
    req._context, req._effect = context, context and context.effect
    local scope = {
        runtime = self,
        request = req,
        owned = {},
        callbacks = 0,
        boundary = boundary,
    }
    scope.co = coroutine.create(function()
        return fn(self, req)
    end)
    req._scope, managed[scope.co] = scope, scope
    self._tasks = self._tasks + 1
    local ok, work = pcall(self._enqueue, self, function()
        self:_resume(scope)
    end)
    if ok then
        scope.work = work
    else
        self:_fail(scope, errors.wrap(work, "host_error"))
    end
    return req
end

function Runtime:start(fn)
    if self._root_scope or self._closing then
        return self:_rejected_request("closed", "runtime root can start only once")
    end
    local req = self:_task(fn)
    self._root_scope = req._scope
    if not req._scope or req._scope.finished then
        self._closing = true
    end
    return req
end

function Runtime:spawn(fn)
    local owner = self:_owner()
    if not owner then
        return self:_rejected_request("closed", "runtime has no live submission scope")
    end
    return self:_task(fn, owner)
end

function Runtime:_operation(fn, context)
    local owner = self:_owner()
    if not owner then
        return self:_rejected_request("closed", "runtime has no live submission scope")
    end
    if context ~= nil and (type(context) ~= "table" or getmetatable(context) ~= nil) then
        return self:_rejected_request("invalid_request", "operation context must be a plain table")
    end
    context = context_copy(context or {})
    context.effect = context.effect or "not_sent"
    return self:_task(fn, owner, context, true)
end

function Budget:bytes()
    return self._bytes
end

function Budget:retain(bytes)
    if not integer(bytes, 0) then
        return nil, errors.new("invalid_options", "retained bytes must be a nonnegative integer")
    end
    local rt = self._runtime
    if self._lease._request or rt._closing then
        return nil, errors.new("closed", "resource byte budget has closed")
    end
    if self._bytes + bytes > self._limit or rt._bytes + bytes > rt._limits.max_bytes then
        return nil, errors.new("queue_full", "resource retained byte limit reached")
    end
    self._bytes = self._bytes + bytes
    rt._bytes, rt._resource_bytes = rt._bytes + bytes, rt._resource_bytes + bytes
    return true
end

function Budget:release(bytes)
    if not integer(bytes, 0) or bytes > self._bytes then
        return nil, errors.new("invalid_options", "released bytes exceed the resource reservation")
    end
    local rt = self._runtime
    self._bytes = self._bytes - bytes
    rt._bytes, rt._resource_bytes = rt._bytes - bytes, rt._resource_bytes - bytes
    return true
end

function Budget:transfer(req, bytes)
    if not integer(bytes, 0) or bytes > self._bytes then
        return nil,
            errors.new("invalid_options", "transferred bytes exceed the resource reservation")
    end
    local rt = self._runtime
    if self._lease._request or rt._closing then
        return nil, errors.new("closed", "resource byte budget has closed")
    end
    if getmetatable(req) ~= Request or req._runtime ~= rt or req._settled or req._retired then
        return nil, errors.new("invalid_request", "byte transfer needs a live same-runtime request")
    end
    self._bytes, rt._resource_bytes = self._bytes - bytes, rt._resource_bytes - bytes
    req._bytes, req._cost = req._bytes + bytes, req._cost + bytes
    return true
end

function Lease:_budget(limit)
    if not integer(limit, 1) then
        return nil, errors.new("invalid_options", "resource byte limit must be a positive integer")
    end
    if self._request or self._runtime._closing then
        return nil, errors.new("closed", "resource byte budget has closed")
    end
    if self._byte_budget and self._byte_budget._limit ~= limit then
        return nil, errors.new("invalid_options", "resource byte budget limit cannot change")
    end
    self._byte_budget = self._byte_budget
        or setmetatable({
            _runtime = self._runtime,
            _lease = self,
            _limit = limit,
            _bytes = 0,
        }, Budget)
    return self._byte_budget
end

function Lease:close()
    if self._request then
        return self._request
    end
    local rt = self._runtime
    local req = request(rt, rt._root_scope)
    req._cleanup = true
    self._request = req
    rt._resources_closing = rt._resources_closing + 1
    local completed, started, starting, notified = false, false, false, false
    local notification
    local function finish(cause)
        if completed then
            return
        end
        completed = true
        if self._byte_budget and self._byte_budget._bytes > 0 then
            cause = errors.new("unreleased_bytes", "resource cleanup retained owned bytes", {
                retained_bytes = self._byte_budget._bytes,
                cause = cause,
            })
        end
        local err = cause ~= nil and cleanup_error(cause) or nil
        if err then
            rt._resources_failed = rt._resources_failed + 1
            rt._resource_error = rt._resource_error or err
            rt:_record(err)
        end
        rt._resources_closing = rt._resources_closing - 1
        remove(rt._resources, self)
        self._close = nil
        req:_settle(err == nil and true or nil, err)
        req:_retire()
    end
    local function done(err)
        if notified then
            return
        end
        notified, notification = true, err
        if not starting then
            finish(err)
        end
    end
    local function start()
        if completed or started then
            return
        end
        started, starting = true, true
        local ok, err = pcall(self._close, done)
        starting = false
        if not ok then
            finish(err)
        elseif notified then
            finish(notification)
        end
    end
    -- Native cleanup must survive a broken dispatcher. This private function
    -- cannot yield or call user code; public completion remains deferred.
    local queued = pcall(rt._enqueue, rt, start, start)
    if not queued then
        start()
    end
    return req
end

function Runtime:_resource(close_fn)
    if not self:_owner() then
        return nil, errors.new("closed", "runtime has no live resource scope")
    end
    if type(close_fn) ~= "function" then
        return nil, errors.new("invalid_resource", "resource needs a cleanup function")
    end
    if #self._resources >= self._limits.max_resources then
        return nil, errors.new("queue_full", "runtime resource admission limit reached")
    end
    local lease = setmetatable({ _runtime = self, _close = close_fn }, Lease)
    self._resources[#self._resources + 1] = lease
    return lease
end

function Runtime:close(reason)
    self._closing = true
    if not self._root_scope then
        self._closed_request = self._closed_request
            or self:_rejected_request("closed", "runtime has no root")
        return self._closed_request
    end
    local root = self._root_scope.request
    if not root._retired then
        self:_abort(self._root_scope, errors.new("cancelled", reason or "runtime closed"))
    end
    return root
end

function Runtime:stats()
    return {
        active = self._active,
        pending = #self._pending,
        logical = self._logical,
        bytes = self._bytes,
        resource_bytes = self._resource_bytes,
        tasks = self._tasks,
        callbacks = self._callbacks,
        resources = #self._resources,
        resources_closing = self._resources_closing,
        resources_failed = self._resources_failed,
        rejected = self._rejected,
        submitted = self._submitted,
        runnable = #self._queue,
        max_active = self._limits.max_active,
        max_pending = self._limits.max_pending,
        max_logical = self._limits.max_logical,
        max_bytes = self._limits.max_bytes,
        max_tasks = self._limits.max_tasks,
        max_callbacks = self._limits.max_callbacks,
        max_resources = self._limits.max_resources,
    }
end

function Runtime:connect(options)
    return require("libtmux._internal.server").connect(self, options)
end

function Runtime:errors()
    local result = {}
    for i, err in ipairs(self._errors) do
        result[i] = err
    end
    return result
end

---@class libtmux.Error
---@field code string
---@field message string
---@field operation? string
---@field effect? "not_sent"|"unknown"|"completed"
---@field cause? unknown
---@field partial? unknown

---@class libtmux.Request<T>
---@field await fun(self:libtmux.Request<T>):T?, libtmux.Error?
---@field result fun(self:libtmux.Request<T>):T?, libtmux.Error?
---@field cancel fun(self:libtmux.Request<T>, reason?:string|libtmux.Error):boolean
---@field is_settled fun(self:libtmux.Request<T>):boolean
---@field is_retired fun(self:libtmux.Request<T>):boolean
---@field on_complete fun(self:libtmux.Request<T>,
--- callback:fun(value:T?, err:libtmux.Error?)):libtmux.Request<T>

---@class libtmux.RuntimeOptions
---@field max_active? integer
---@field max_pending? integer
---@field max_logical? integer
---@field max_bytes? integer
---@field max_tasks? integer
---@field max_callbacks? integer
---@field max_resources? integer
---@field dispatch_budget? integer

---@class libtmux.Runtime
---@field connect fun(self:libtmux.Runtime,
--- options:libtmux.ConnectOptions):libtmux.Request<libtmux.Server>
---@field spawn fun<T>(self:libtmux.Runtime,
--- body:fun(runtime:libtmux.Runtime):T?, libtmux.Error?):libtmux.Request<T>
---@field close fun(self:libtmux.Runtime, reason?:string):libtmux.Request<unknown>
---@field stats fun(self:libtmux.Runtime):table<string, integer>
---@field errors fun(self:libtmux.Runtime):libtmux.Error[]

return M
