-- luv, typed loosely: LuaLS would otherwise resolve require("luv") to libtmux.runtime.luv, the
-- library's adapter, which a script does not mean.
---@type any
---@diagnostic disable-next-line: different-requires
local uv = require("luv")

return uv
