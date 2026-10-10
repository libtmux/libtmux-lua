local host = rawget(_G, "vim")
-- luv is the native host module, distinct from libtmux.runtime.luv.
---@diagnostic disable-next-line: different-requires
local uv = host and (host.uv or host.loop) or require("luv")
local spawn = uv.spawn
uv.spawn = function(binary, options, callback)
    local handle, pid = spawn(binary, options, callback)
    local daemon = false
    for _, argument in ipairs(options.args or {}) do
        if argument == "-D" then
            daemon = true
        end
    end
    if handle and daemon then
        local directory = assert(os.getenv("LIBTMUX_OBSERVER"))
        local file = assert(io.open(directory .. "/spawn-" .. pid, "w"))
        file:write(tostring(pid))
        file:close()
        local started = uv.hrtime()
        while true do
            local ack = io.open(directory .. "/ack-spawn-" .. pid, "r")
            if ack then
                assert(ack:read("*a") == "accepted")
                ack:close()
                break
            end
            assert(
                (uv.hrtime() - started) / 1000000 < 750,
                "external daemon identity acceptance timed out"
            )
            uv.sleep(1)
        end
    end
    return handle, pid
end

local mode = os.getenv("LIBTMUX_WORKER_MODE")
if mode then
    local original_print = print
    -- The worker-local hook injects failure without editing the example file.
    -- luacheck: push globals print
    print = function(...)
        original_print(...)
        io.stdout:flush()
        if mode == "body-fail" then
            error("outer harness injected body failure after example output", 0)
        elseif mode == "crash" then
            uv.kill(uv.os_getpid(), "sigkill")
        elseif mode == "timeout" then
            while true do
                uv.sleep(100)
            end
        end
    end
    -- luacheck: pop
end
