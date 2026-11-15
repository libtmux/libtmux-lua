-- Lua cannot change its environment, so scripts/check/check.lua or tests/run_integration.lua makes
-- the sandbox (tests/support/sandbox_host.lua) and this checks that it holds. Findings name
-- variables and never print their values.
local M = {}

M.MARKER = "LIBTMUX_TEST_SANDBOX"
M.PREFIX = "libtmux-lua-sb-"
M.MAX_BYTES = 60
-- Lua cannot list its environment, so it looks up the selectors the library and its ports read.
M.SELECTORS =
    { "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_NAME", "LIBTMUX_SOCKET_PATH", "TMUX", "TMUX_PANE" }

---@param name string
---@return boolean
function M.ambient(name)
    return name == "TMUX" or name == "TMUX_PANE" or name:sub(1, 14) == "LIBTMUX_SOCKET"
end

--- What is wrong with TMUX_TMPDIR as a sandbox directory, from the strings alone.
---@param getenv fun(name: string): string?
---@return string[] findings
function M.directory_findings(getenv)
    local found = {}
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

---@param getenv fun(name: string): string?
---@return string[] findings
function M.violations(getenv)
    local found = {}
    for _, name in ipairs(M.SELECTORS) do
        if getenv(name) ~= nil then
            found[#found + 1] = name .. " is set"
        end
    end
    for _, finding in ipairs(M.directory_findings(getenv)) do
        found[#found + 1] = finding
    end
    return found
end

return M
