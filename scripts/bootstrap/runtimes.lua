-- Build pinned Lua interpreters into .cache/toolchains. Runs before the tool interpreter exists,
-- so it uses only the standard library and the build tools on PATH.
local files = require("support.files")
local repo = require("support.repo")
local shell = require("support.shell")

local M = {}

M.RELEASES = {
    ["5.1.5"] = "2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333",
    ["5.2.4"] = "b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b",
    ["5.3.6"] = "fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60",
    ["5.4.9"] = "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6",
    ["5.5.1"] = "1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce",
}
M.ATTEMPTS = 4
M.LUAJIT_REVISION = "c6ffc141a8762b41703f9287d63d93622a13dd8f"
M.LUAJIT_REPOSITORY = "https://github.com/LuaJIT/LuaJIT.git"

local function say(fields)
    local keys = {}
    for key in pairs(fields) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = fields[key]
        parts[#parts + 1] = ('"%s": %s'):format(
            key,
            type(value) == "number" and value or ('"' .. value .. '"')
        )
    end
    print("{" .. table.concat(parts, ", ") .. "}")
end

--- lua.org times out from runners now and then, so curl retries a transient failure a bounded
--- number of times. The caller checks the SHA256, so a retry cannot weaken the pin.
---@param url string
---@param destination string
---@return string[]
function M.download_command(url, destination)
    return {
        "curl",
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--max-time",
        "60",
        "--retry",
        tostring(M.ATTEMPTS - 1),
        "--retry-delay",
        "5",
        "--retry-all-errors",
        "--output",
        destination,
        url,
    }
end

M.sha256 = shell.sha256

local function build_lua(version, source, toolchains)
    local prefix = toolchains .. "/lua-" .. version
    if files.exists(prefix .. "/bin/lua") then
        print(shell.check({ prefix .. "/bin/lua", "-v" }):match("[^\n]+"))
        return
    end
    local started = os.time()
    local name = "lua-" .. version .. ".tar.gz"
    local archive = source .. "/" .. name
    if not files.exists(archive) then
        shell.check(M.download_command("https://www.lua.org/ftp/" .. name, archive))
    end
    if M.sha256(archive) ~= M.RELEASES[version] then
        error("SHA256 mismatch: " .. name, 0)
    end
    shell.check({ "tar", "-xzf", archive, "-C", source })
    local directory = source .. "/lua-" .. version
    local linux = shell.check({ "uname", "-s" }):match("Linux") ~= nil
    local log = source .. "/lua-" .. version .. "-build.log"
    shell.check({
        "make",
        "-C",
        "src",
        "-j4",
        "all",
        "MYCFLAGS=-DLUA_USE_POSIX -DLUA_USE_DLOPEN -fPIC",
        "MYLIBS=" .. (linux and "-Wl,-E -ldl" or ""),
    }, { cwd = directory, log = log })
    shell.check({ "make", "install", "INSTALL_TOP=" .. prefix }, { cwd = directory, log = log })
    print(shell.check({ prefix .. "/bin/lua", "-v" }):match("[^\n]+"))
    say({
        runtime = version,
        source_sha256 = M.RELEASES[version],
        bootstrap_seconds = os.time() - started,
    })
end

local function build_luajit(source, toolchains)
    local directory = source .. "/luajit"
    local prefix = toolchains .. "/luajit-2.1"
    local started = os.time()
    if not files.exists(directory .. "/.git/HEAD") then
        shell.check({
            "git",
            "clone",
            "--filter=blob:none",
            "--no-checkout",
            "--",
            M.LUAJIT_REPOSITORY,
            directory,
        })
        shell.check({ "git", "-C", directory, "checkout", "--detach", M.LUAJIT_REVISION })
    end
    local revision = shell.check({ "git", "-C", directory, "rev-parse", "HEAD" }):match("%x+")
    if revision ~= M.LUAJIT_REVISION then
        error("Cached LuaJIT checkout differs from the accepted revision", 0)
    end
    local dirty =
        shell.check({ "git", "-C", directory, "status", "--porcelain", "--untracked-files=no" })
    if dirty ~= "" then
        error("Cached LuaJIT tracked source has local edits", 0)
    end
    local log = source .. "/luajit-build.log"
    shell.check({ "make", "-j4", "PREFIX=" .. prefix }, { cwd = directory, log = log })
    shell.check({ "make", "install", "PREFIX=" .. prefix }, { cwd = directory, log = log })
    print(shell.check({ prefix .. "/bin/luajit", "-v" }):match("[^\n]+"))
    say({
        runtime = "LuaJIT 2.1",
        source_revision = revision,
        bootstrap_seconds = os.time() - started,
    })
end

--- Builds each named runtime: a PUC Lua release from RELEASES, or `luajit`.
---@param versions string[]
function M.main(versions)
    if #versions == 0 then
        error("usage: bootstrap.lua runtimes VERSION... (5.1.5 ... 5.5.1, luajit)", 0)
    end
    for _, version in ipairs(versions) do
        if version ~= "luajit" and not M.RELEASES[version] then
            error("Unknown runtime: " .. version, 0)
        end
    end
    local system = shell.check({ "uname", "-s" }):match("%a+")
    if system ~= "Linux" and system ~= "Darwin" then
        error("Bootstrap supports Linux and macOS only", 0)
    end
    local source = repo.root .. "/.cache/source"
    local toolchains = repo.root .. "/.cache/toolchains"
    shell.check({ "mkdir", "-p", source, toolchains })
    for _, version in ipairs(versions) do
        if version == "luajit" then
            build_luajit(source, toolchains)
        else
            build_lua(version, source, toolchains)
        end
    end
end

return M
