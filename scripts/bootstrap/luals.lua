-- Install the pinned LuaLS release into .cache/tools, the language server the types gate and the
-- documentation exporter run.
local repo = require("support.repo")
local runtimes = require("bootstrap.runtimes")
local shell = require("support.shell")

local M = {}

M.VERSION = "3.19.1"
M.ARTIFACTS = {
    ["Linux x86_64"] = {
        "linux-x64",
        "e9235d2d72ef55bc41cf8c99cda2ed64777682024b4bb81f5dea425060c5cbb8",
    },
    ["Darwin arm64"] = {
        "darwin-arm64",
        "0bc077f4447f076b4c92c14e9fd303f5b569eda2ec74b4dca2b55f75fae2e90c",
    },
}

function M.main()
    local host = shell.check({ "uname", "-sm" }):match("^(.-)%s*$")
    local artifact = M.ARTIFACTS[host]
    if not artifact then
        error("No pinned LuaLS bootstrap artifact for " .. host, 0)
    end
    local name = ("lua-language-server-%s-%s.tar.gz"):format(M.VERSION, artifact[1])
    local source = repo.root .. "/.cache/source"
    local archive = source .. "/" .. name
    shell.check({ "mkdir", "-p", source })
    if not io.open(archive, "rb") then
        local url = ("https://github.com/LuaLS/lua-language-server/releases/download/%s/%s"):format(
            M.VERSION,
            name
        )
        shell.check(runtimes.download_command(url, archive))
    end
    if runtimes.sha256(archive) ~= artifact[2] then
        error("LuaLS artifact SHA256 mismatch", 0)
    end
    local prefix = repo.root .. "/.cache/tools/luals-" .. M.VERSION
    shell.check({ "mkdir", "-p", prefix })
    shell.check({ "tar", "-xzf", archive, "-C", prefix })
end

return M
