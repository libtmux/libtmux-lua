-- luv is a binary host module, distinct from libtmux.runtime.luv.
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
---@cast uv {new_timer:(fun():table), loop_alive:(fun():boolean), run:(fun(mode?:string):boolean)}
local adapter = require("libtmux.runtime.luv")
local called, continued = false, false
local timer = uv.new_timer()
timer:start(0, 0, function()
    assert(not uv.loop_alive(), "probe must cover a quiescent running callback")
    local _, err = adapter.run(function()
        called = true
    end)
    assert(err and err.code == "invalid_run_context")
    continued = true
    timer:close()
end)
uv.run()
assert(continued and not called)
assert(not uv.loop_alive())
print("Foreign luv callback rejection PASS")
