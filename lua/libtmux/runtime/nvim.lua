local runtime = require("libtmux._internal.runtime")
local luv = require("libtmux.runtime.luv")
local errors = require("libtmux._internal.error")
local M = {}

-- Inline generics preserve the body callback's contextual type in LuaLS.
---@type fun<T>(
--- fn:(fun(runtime:libtmux.Runtime):T?, libtmux.Error?),
--- on_done:fun(value:T?, err:libtmux.Error?),
--- options?:libtmux.RuntimeOptions):libtmux.Runtime?, libtmux.Request<T>|libtmux.Error
function M.start(fn, on_done, options)
    local host = rawget(_G, "vim")
    if not host or not host.schedule or not (host.uv or host.loop) then
        return nil,
            errors.new("unsupported_host", "Neovim runtime requires vim.uv and vim.schedule")
    end
    if type(on_done) ~= "function" then
        return nil, errors.new("invalid_callback", "Neovim start needs a completion callback")
    end
    local driver = luv._driver(host.uv or host.loop, host.schedule)
    local rt = runtime.new(driver, options)
    local root
    rt._on_close = function()
        driver.after_idle(function()
            local value, err = luv._result(root, rt)
            local ok, cause = pcall(on_done, value, err)
            if not ok then
                rt:_record(errors.wrap(cause, "callback_error"))
            end
        end)
    end
    root = rt:start(fn)
    if root:is_retired() then
        local ok, err = pcall(rt._on_close)
        if not ok then
            return nil, errors.wrap(err, "host_error")
        end
    end
    return rt, root
end

return M
