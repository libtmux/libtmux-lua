-- luacheck: globals vim
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local adapter = require("libtmux.runtime.nvim")
local uv = vim.uv or vim.loop
local _, host_error = require("libtmux.runtime.luv").run(function()
    error("standalone adapter entered the Neovim loop")
end)
assert(host_error and host_error.code == "invalid_run_context")
local borrowed = uv.new_timer()
borrowed:start(10000, 0, function() end)
local watchdog = uv.new_timer()
local function fail(err)
    io.stderr:write(tostring(err), "\n")
    vim.cmd("cquit 1")
end
watchdog:start(500, 0, function()
    vim.schedule(function()
        fail("Neovim runtime completion stalled")
    end)
end)
local function check(fn)
    local ok, err = pcall(fn)
    if not ok then
        fail(err)
    end
end

local returned, callback_seen, unrelated = false, false, false
local tick = uv.new_timer()
tick:start(0, 0, function()
    unrelated = true
    tick:close()
end)
local rt, root
rt, root = adapter.start(function(runtime)
    ---@cast runtime libtmux.TestRuntime
    assert(returned, "start drove the borrowed host loop")
    local req = runtime:_request({
        timeout = 100,
        start = function(settle, retire)
            runtime._driver.timer(0, function()
                settle("done")
                retire()
            end)
        end,
    })
    req:on_complete(function()
        assert(not vim.in_fast_event(), "completion ran in a fast event")
        callback_seen = true
    end)
    return req:await()
end, function(value, err)
    check(function()
        assert(value == "done" and err == nil, tostring(err))
        ---@cast root libtmux.Request<string>
        ---@cast rt libtmux.TestRuntime
        assert(root:is_retired() and callback_seen and unrelated)
        assert(not vim.in_fast_event())
        assert(not borrowed:is_closing(), "adapter closed borrowed handle")
        assert(rt and rt._driver.pending == 0, "on_done preceded timer cleanup")
        local retired, failed_rt
        failed_rt = adapter.start(function(runtime)
            ---@cast runtime libtmux.TestRuntime
            runtime:_request({
                start = function(_, retire)
                    return function()
                        runtime._driver.timer(0, function()
                            retired = true
                            retire()
                        end)
                    end
                end,
            })
            runtime
                :_request({
                    start = function(settle, retire)
                        settle(true)
                        retire()
                    end,
                })
                :await()
            error({ code = "expected_failure" })
        end, function(_, failure)
            check(function()
                ---@cast failed_rt libtmux.TestRuntime
                assert(failure and failure.code == "expected_failure")
                assert(retired and failed_rt and failed_rt:stats().active == 0)
                assert(failed_rt and failed_rt._driver.pending == 0)
                local calls = 0
                ---@diagnostic disable-next-line: param-type-mismatch
                adapter.start(nil, function(_, invalid)
                    check(function()
                        calls = calls + 1
                        assert(calls == 1 and invalid and invalid.code == "invalid_task")
                        assert(not vim.in_fast_event())
                        borrowed:stop()
                        borrowed:close()
                        watchdog:stop()
                        watchdog:close(function()
                            vim.schedule(function()
                                print("Neovim runtime smoke PASS")
                                vim.cmd("qa!")
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end)
returned = true
