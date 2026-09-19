local errors = require("libtmux._internal.error")
local M = {}

-- Native lifetime is resource-owned, independent of one-shot runtime admission.
function M.start(runtime, endpoint, options, on_data, on_end)
    local driver, uv = runtime._driver, runtime._driver.uv
    local transport, pipes, closing = {}, {}, {}
    local child, started, exited, finished, shutting = nil, false, false, false, false
    local open, writes, stderr_bytes, code, signal = 0, 0, 0, 0, 0
    local eof, timers = {}, {}
    local terminal, cleanup_error, close_done
    local notified_close = false
    local notified_end = false
    local notifying_end = false
    local check, abort

    local function failure(kind, message, cause)
        return errors.new(kind, message, {
            operation = "control",
            effect = started and "unknown" or "not_sent",
            cause = cause,
            partial = {
                exit_code = exited and code or nil,
                signal = exited and signal or nil,
                stderr_bytes = stderr_bytes,
            },
        })
    end

    local function notify_close()
        if close_done and not notified_close and not notifying_end then
            notified_close = true
            close_done(cleanup_error)
        end
    end

    local function notify_end()
        if notified_end then
            return
        end
        notified_end, notifying_end = true, true
        local notified, notification_error = pcall(on_end, terminal)
        notifying_end = false
        if not notified then
            cleanup_error = cleanup_error
                or failure("cleanup_failed", "control terminal observer failed", notification_error)
        end
    end

    local function stop_timer(name)
        local cancel = timers[name]
        timers[name] = nil
        if cancel then
            local ok, cause = pcall(cancel)
            if not ok then
                cleanup_error = cleanup_error
                    or failure("cleanup_failed", "control timer cleanup failed", cause)
            end
        end
    end

    local function close(handle)
        if not handle or closing[handle] then
            return
        end
        closing[handle] = true
        local ok, cause = pcall(handle.close, handle, function()
            open = open - 1
            check()
        end)
        if not ok then
            cleanup_error = cleanup_error
                or failure("cleanup_failed", "control handle close failed", cause)
        end
    end

    local function kill(which)
        if child and not exited then
            local ok, result, cause = pcall(child.kill, child, which)
            if not ok or result == nil or result == false then
                cleanup_error = cleanup_error
                    or failure(
                        "cleanup_failed",
                        "control client signal failed",
                        ok and cause or result
                    )
            end
        end
    end

    local function timer(name, delay, fn)
        stop_timer(name)
        local ok, cancel, cause = pcall(driver.timer, delay, function()
            timers[name] = nil
            fn()
        end)
        if not ok or type(cancel) ~= "function" then
            return nil,
                failure("timer_failed", "control timer creation failed", ok and cause or cancel)
        end
        timers[name] = cancel
        return true
    end

    local function escalate()
        kill("sigterm")
        local ok, err = timer("kill", 100, function()
            kill("sigkill")
        end)
        if not ok then
            cleanup_error = cleanup_error or err
            kill("sigkill")
        end
    end

    check = function()
        if finished or (started and not exited) or open > 0 or writes > 0 then
            return
        end
        finished = true
        stop_timer("drain")
        stop_timer("close")
        stop_timer("kill")
        if not terminal and not shutting and (code ~= 0 or signal ~= 0) then
            terminal = failure("connection_lost", "control client exited unsuccessfully")
        end
        notify_end()
        notify_close()
    end

    abort = function(err)
        if finished then
            return
        end
        terminal = terminal or err
        for _, pipe in ipairs(pipes) do
            close(pipe)
        end
        stop_timer("drain")
        stop_timer("close")
        if child and not exited then
            escalate()
        end
        check()
    end

    function transport.write(_, data, callback)
        if shutting or terminal or finished then
            return nil, terminal or failure("closed", "control input is closed")
        end
        writes = writes + 1
        local called = false
        local function written(err)
            if called then
                return
            end
            called = true
            writes = writes - 1
            local notified, notification_error = pcall(
                callback,
                err and failure("write_failed", "control input write failed", err) or nil
            )
            if not notified then
                cleanup_error = cleanup_error
                    or failure(
                        "cleanup_failed",
                        "control write observer failed",
                        notification_error
                    )
                abort(
                    failure("protocol_error", "control write observer failed", notification_error)
                )
            end
            if err and not shutting then
                abort(failure("write_failed", "control input write failed", err))
            end
            check()
        end
        local ok, value, cause = pcall(pipes[1].write, pipes[1], data, written)
        if not ok or value == nil or value == false then
            written(ok and cause or value)
            return nil, terminal or failure("write_failed", "control input write failed", cause)
        end
        return true
    end

    function transport.close(_, done)
        if close_done then
            return
        end
        close_done, shutting = done, true
        if finished then
            notify_close()
            return
        end
        close(pipes[1])
        if child and not exited and not terminal then
            local ok, err = timer("close", 100, escalate)
            if not ok then
                cleanup_error = cleanup_error or err
                kill("sigkill")
            end
        end
        check()
    end

    function transport.fail(_, err)
        abort(err)
    end

    if not uv then
        local err = failure("unsupported", "control requires asynchronous process support")
        terminal = err
        check()
        return transport, err
    end
    for index = 1, 3 do
        local ok, pipe, cause = pcall(uv.new_pipe, false)
        if not ok or not pipe then
            local err =
                failure("spawn_failed", "control pipe creation failed", ok and cause or pipe)
            abort(err)
            return transport, err
        end
        pipes[index], open = pipe, open + 1
    end
    local args = { "-N", "-S", endpoint.socket, "-u" }
    if endpoint.config then
        args[#args + 1], args[#args + 2] = "-f", endpoint.config
    end
    for _, arg in ipairs({
        "-C",
        "attach-session",
        "-E",
        "-f",
        "ignore-size,active-pane",
        "-t",
        options.session_id,
    }) do
        args[#args + 1] = arg
    end
    local ok, handle, cause = pcall(
        uv.spawn,
        endpoint.binary,
        { args = args, stdio = pipes },
        function(status, term_signal)
            exited, code, signal = true, status, term_signal
            close(child)
            close(pipes[1])
            stop_timer("close")
            stop_timer("kill")
            if not terminal and not (eof[1] and eof[2]) then
                local accepted, err = timer("drain", 250, function()
                    abort(failure("drain_timeout", "control output did not reach EOF after exit"))
                end)
                if not accepted then
                    abort(err)
                end
            end
            check()
        end
    )
    if not ok or not handle then
        local err = failure("spawn_failed", "control client spawn failed", ok and cause or handle)
        abort(err)
        return transport, err
    end
    child, started, open = handle, true, open + 1
    for index = 1, 2 do
        local stream = index
        local pipe = pipes[index + 1]
        local accepted, value, read_error = pcall(pipe.read_start, pipe, function(err, data)
            if finished then
                return
            end
            if err then
                abort(failure("read_failed", "control output read failed", err))
            elseif data == nil then
                eof[stream] = true
                close(pipe)
                if stream == 1 and not exited and not shutting and not terminal then
                    abort(failure("unexpected_eof", "control output ended before client exit"))
                    notify_end()
                end
                if eof[1] and eof[2] then
                    stop_timer("drain")
                end
            elseif not terminal then
                if stream == 1 then
                    local delivered, delivery_error = pcall(on_data, data)
                    if not delivered then
                        abort(
                            failure(
                                "protocol_error",
                                "control reader callback failed",
                                delivery_error
                            )
                        )
                    end
                else
                    stderr_bytes = stderr_bytes + #data
                    if stderr_bytes > 16384 then
                        abort(failure("output_limit", "control diagnostic byte limit reached"))
                    end
                end
            end
        end)
        if not accepted or value == nil or value == false then
            local err = failure(
                "read_failed",
                "control output read start failed",
                accepted and read_error or value
            )
            abort(err)
            return transport, err
        end
    end
    return transport
end

return M
