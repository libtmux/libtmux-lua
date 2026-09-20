local errors = require("libtmux._internal.error")
local M = {}

local function text(value)
    return type(value) == "string" and not value:find("\000", 1, true)
end

local function sequence(values, nonempty)
    if type(values) ~= "table" or getmetatable(values) ~= nil then
        return nil
    end
    local copy, bytes, count, last = {}, 0, 0, 0
    for key in next, values do
        local value = rawget(values, key)
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or not text(value) then
            return nil
        end
        copy[key], bytes, count = value, bytes + #value, count + 1
        last = math.max(last, key)
    end
    if count ~= last or (nonempty and count == 0) then
        return nil
    end
    return copy, bytes
end

local function positive(value, maximum)
    return type(value) == "number" and value > 0 and value <= maximum and value % 1 == 0
end

function M.prepare(argv, options)
    local args, bytes = sequence(argv, true)
    local invalid
    if not args or args[1] == "" then
        invalid =
            errors.new("invalid_argv", "process argv needs an executable and NUL-free strings")
    end
    if options == nil then
        options = {}
    end
    local opts = {}
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        invalid = invalid or errors.new("invalid_options", "process options must be a plain table")
    else
        for key in next, options do
            local value = rawget(options, key)
            if
                key ~= "stdin"
                and key ~= "cwd"
                and key ~= "env"
                and key ~= "timeout"
                and key ~= "deadline"
                and key ~= "max_output_bytes"
                and key ~= "drain_timeout"
                and key ~= "kill_timeout"
            then
                invalid = invalid or errors.new("invalid_options", "unknown process option")
            end
            opts[key] = value
        end
    end
    for key, default in pairs({
        max_output_bytes = 1024 * 1024,
        drain_timeout = 250,
        kill_timeout = 100,
    }) do
        if opts[key] == nil then
            opts[key] = default
        end
    end
    if
        (opts.stdin ~= nil and type(opts.stdin) ~= "string")
        or (opts.cwd ~= nil and not text(opts.cwd))
        or not positive(opts.max_output_bytes, 2 ^ 53)
        or not positive(opts.drain_timeout, 1000)
        or not positive(opts.kill_timeout, 1000)
    then
        invalid = invalid
            or errors.new("invalid_options", "invalid process input, output cap or deadline")
    end
    if opts.env ~= nil then
        opts.env = sequence(opts.env, false)
        if not opts.env then
            invalid = invalid or errors.new("invalid_options", "process env needs NUL-free strings")
        else
            for _, item in ipairs(opts.env) do
                bytes = (bytes or 0) + #item
            end
        end
    end
    if invalid then
        invalid.effect, invalid.operation = "not_sent", "process"
        return nil, invalid
    end
    return { argv = args, options = opts, bytes = bytes + #(opts.stdin or "") + #(opts.cwd or "") }
end

function M.retain_output(request, result, err, operation)
    local stdout_bytes, stderr_bytes, output = 0, 0, nil
    local seen = {}
    local function account(value)
        if type(value) ~= "table" or seen[value] then
            return
        end
        seen[value] = true
        local stdout, stderr = rawget(value, "stdout"), rawget(value, "stderr")
        if type(stdout) == "string" and type(stderr) == "string" then
            output = output or value
            stdout_bytes, stderr_bytes = stdout_bytes + #stdout, stderr_bytes + #stderr
        end
    end
    account(result)
    local cursor, depth = err, 0
    while type(cursor) == "table" and not seen[cursor] and depth < 16 do
        seen[cursor], depth = true, depth + 1
        account(rawget(cursor, "partial"))
        cursor = rawget(cursor, "cause")
    end
    local accepted, cause
    if type(cursor) == "table" and not seen[cursor] then
        cause = errors.new("queue_full", "process error context exceeds its retention limit")
    else
        accepted, cause = request:_retain(stdout_bytes + stderr_bytes)
    end
    if not accepted then
        return nil,
            errors.new("queue_full", "retained process output byte limit reached", {
                operation = operation,
                effect = result and "completed" or err and err.effect or "unknown",
                cause = cause,
                partial = {
                    output_truncated = true,
                    stdout_bytes = stdout_bytes,
                    stderr_bytes = stderr_bytes,
                    exit_code = output and output.exit_code,
                    signal = output and output.signal,
                },
            })
    end
    return result, err
end

function M.execute(runtime, argv, options)
    local prepared, invalid = M.prepare(argv, options)
    if not prepared then
        return runtime:_request({
            bytes = 0,
            start = function(settle, retire)
                settle(nil, invalid)
                retire()
            end,
        })
    end
    local args, opts, bytes = prepared.argv, prepared.options, prepared.bytes
    ---@cast args string[]
    local program = table.remove(args, 1)
    return runtime:_request({
        bytes = bytes,
        deadline = opts.deadline,
        timeout = opts.timeout,
        effect = "not_sent",
        operation = "process",
        target = program,
        start = function(settle, retire, request)
            local uv = runtime._driver.uv
            if not uv then
                settle(
                    nil,
                    errors.new("unsupported", "runtime has no process driver", {
                        operation = "process",
                        target = program,
                        effect = "not_sent",
                    })
                )
                retire()
                return
            end
            local stdout, stderr, pipes = {}, {}, {}
            local child, exited, started, failed, done
            local code, signal, open, retained = nil, nil, 0, 0
            local cancel_drain, cancel_kill, cleanup_error
            local eof = { false, false }
            local closing = {}
            local check, abort

            local function result()
                return {
                    stdout = table.concat(stdout),
                    stderr = table.concat(stderr),
                    exit_code = code,
                    signal = signal,
                }
            end

            local function effect()
                return exited and "completed" or started and "unknown" or "not_sent"
            end

            local function failure(kind, message, cause)
                return errors.new(kind, message, {
                    operation = "process",
                    target = program,
                    cause = cause,
                    effect = effect(),
                    partial = result(),
                })
            end

            local function close(handle)
                if not handle or closing[handle] then
                    return
                end
                closing[handle] = true
                handle:close(function()
                    open = open - 1
                    check()
                end)
            end

            local function stop_timer(cancel)
                if cancel then
                    local called, cause = pcall(cancel)
                    if not called then
                        cleanup_error = cleanup_error
                            or failure("cleanup_failed", "process timer cleanup failed", cause)
                    end
                end
                return nil
            end

            local function stop_timers()
                cancel_drain = stop_timer(cancel_drain)
                cancel_kill = stop_timer(cancel_kill)
            end

            check = function()
                if done or (started and not exited) or open > 0 then
                    return
                end
                done = true
                stop_timers()
                if not failed then
                    if code ~= 0 or signal ~= 0 then
                        settle(nil, failure("exit_failed", "process exited unsuccessfully", code))
                    else
                        settle(result(), nil)
                    end
                end
                retire(cleanup_error)
            end

            local function kill(which)
                if child and not exited then
                    local called, value, cause = pcall(child.kill, child, which)
                    if not called or value == nil or value == false then
                        cleanup_error = cleanup_error
                            or failure(
                                "cleanup_failed",
                                "process signal failed",
                                called and cause or value
                            )
                    end
                end
            end

            local function timer(delay, callback)
                local called, cancel, cause = pcall(runtime._driver.timer, delay, callback)
                if not called then
                    return nil, cancel
                elseif type(cancel) ~= "function" then
                    return nil, cause or "timer did not return a cancellation function"
                end
                return cancel
            end

            abort = function(err)
                if failed or done then
                    return
                end
                failed = true
                settle(nil, err)
                stop_timers()
                for _, pipe in ipairs(pipes) do
                    close(pipe)
                end
                if child and not exited then
                    kill("sigterm")
                    local timer_error
                    cancel_kill, timer_error = timer(opts.kill_timeout, function()
                        cancel_kill = nil
                        kill("sigkill")
                    end)
                    if not cancel_kill then
                        cleanup_error = cleanup_error
                            or failure("cleanup_failed", "process kill timer failed", timer_error)
                        kill("sigkill")
                    end
                end
                check()
            end

            for i = 1, 3 do
                local called, pipe, cause = pcall(uv.new_pipe, false)
                if not called or not pipe then
                    abort(
                        failure(
                            "spawn_failed",
                            "process pipe creation failed",
                            called and cause or pipe
                        )
                    )
                    return
                end
                pipes[i], open = pipe, open + 1
            end
            local called, handle, cause = pcall(uv.spawn, program, {
                args = args,
                stdio = pipes,
                cwd = opts.cwd,
                env = opts.env,
            }, function(status, term_signal)
                exited, code, signal = true, status, term_signal
                request:_set_effect("completed")
                close(child)
                if not failed and not (eof[1] and eof[2]) then
                    local timer_error
                    cancel_drain, timer_error = timer(opts.drain_timeout, function()
                        cancel_drain = nil
                        abort(
                            failure("drain_timeout", "process output did not reach EOF after exit")
                        )
                    end)
                    if not cancel_drain then
                        abort(
                            failure(
                                "timer_failed",
                                "process output drain timer failed",
                                timer_error
                            )
                        )
                    end
                end
                if cancel_kill then
                    cancel_kill = stop_timer(cancel_kill)
                end
                check()
            end)
            if not called or not handle then
                abort(failure("spawn_failed", "process spawn failed", called and cause or handle))
                return
            end
            child, started, open = handle, true, open + 1
            request:_set_effect("unknown")

            for index = 1, 2 do
                local stream_index = index
                local pipe, chunks = pipes[index + 1], index == 1 and stdout or stderr
                local read_ok, value, read_error = pcall(pipe.read_start, pipe, function(err, data)
                    if failed or done then
                        return
                    end
                    if err then
                        abort(failure("read_failed", "process output read failed", err))
                    elseif data == nil then
                        eof[stream_index] = true
                        close(pipe)
                        if eof[1] and eof[2] and cancel_drain then
                            cancel_drain = stop_timer(cancel_drain)
                        end
                    else
                        if retained + #data > opts.max_output_bytes then
                            abort(failure("output_limit", "process output byte limit reached"))
                            return
                        end
                        local accepted, retain_error = request:_retain(#data)
                        if not accepted then
                            abort(
                                failure(
                                    "queue_full",
                                    "runtime output byte limit reached",
                                    retain_error
                                )
                            )
                            return
                        end
                        retained = retained + #data
                        chunks[#chunks + 1] = data
                    end
                end)
                if not read_ok or value == nil or value == false then
                    abort(
                        failure(
                            "read_failed",
                            "process output read start failed",
                            read_ok and read_error or value
                        )
                    )
                    break
                end
            end
            if not failed and opts.stdin and #opts.stdin > 0 then
                local write_ok, value, write_error = pcall(
                    pipes[1].write,
                    pipes[1],
                    opts.stdin,
                    function(err)
                        if failed or done then
                            return
                        end
                        if err then
                            abort(failure("write_failed", "process input write failed", err))
                            return
                        end
                        local shutdown_ok, shutdown_value, shutdown_error = pcall(
                            pipes[1].shutdown,
                            pipes[1],
                            function(shutdown_err)
                                if shutdown_err and not failed then
                                    abort(
                                        failure(
                                            "write_failed",
                                            "process input shutdown failed",
                                            shutdown_err
                                        )
                                    )
                                else
                                    close(pipes[1])
                                end
                            end
                        )
                        if not shutdown_ok or shutdown_value == nil or shutdown_value == false then
                            abort(
                                failure(
                                    "write_failed",
                                    "process input shutdown failed",
                                    shutdown_ok and shutdown_error or shutdown_value
                                )
                            )
                        end
                    end
                )
                if not write_ok or value == nil or value == false then
                    abort(
                        failure(
                            "write_failed",
                            "process input write failed",
                            write_ok and write_error or value
                        )
                    )
                end
            else
                close(pipes[1])
            end
            return function(err)
                err.effect, err.operation, err.target, err.partial =
                    effect(), "process", program, result()
                abort(err)
            end
        end,
    })
end

return M
