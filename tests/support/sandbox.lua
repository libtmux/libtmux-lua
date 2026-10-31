-- Lua cannot change its environment, so scripts/check.py or tests/run_integration.py makes the
-- sandbox (tests/support/sandbox.py) and this checks that it holds. Findings name variables and
-- never print their values.
local M = {}

M.MARKER = "LIBTMUX_TEST_SANDBOX"
M.PREFIX = "libtmux-lua-sb-"
M.MAX_BYTES = 60
-- Lua cannot list its environment, so it looks up the selectors the library and its ports read.
M.SELECTORS =
    { "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_NAME", "LIBTMUX_SOCKET_PATH", "TMUX", "TMUX_PANE" }

---@param getenv fun(name: string): string?
---@return string[] findings
function M.violations(getenv)
    local found = {}
    for _, name in ipairs(M.SELECTORS) do
        if getenv(name) ~= nil then
            found[#found + 1] = name .. " is set"
        end
    end
    local directory = getenv("TMUX_TMPDIR")
    local base = directory and directory:match("([^/]+)/*$")
    if directory == nil or directory == "" then
        found[#found + 1] = "TMUX_TMPDIR is unset"
    elseif directory:sub(1, 1) ~= "/" then
        found[#found + 1] = "TMUX_TMPDIR is not an absolute path"
    elseif #directory > M.MAX_BYTES then
        found[#found + 1] = "TMUX_TMPDIR is longer than " .. M.MAX_BYTES .. " bytes"
    elseif getenv(M.MARKER) ~= directory or not base or base:sub(1, #M.PREFIX) ~= M.PREFIX then
        found[#found + 1] = "TMUX_TMPDIR is not the sandbox directory of this run"
    end
    return found
end

return M
