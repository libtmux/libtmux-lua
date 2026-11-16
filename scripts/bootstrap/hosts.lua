-- Install the pinned Neovim hosts into .cache/toolchains, outside every test loop, and probe each
-- one: the executable, its checksum receipt and its embedded Lua runtime.
local files = require("support.files")
local json = require("support.json")
local repo = require("support.repo")
local runtimes = require("bootstrap.runtimes")
local shell = require("support.shell")

local M = {}

-- v0.10.x checksum assets and v0.11+ release asset digests, all for Linux x86_64.
M.RELEASES = {
    ["0.10.0"] = {
        "nvim-linux64",
        "be1f0988d0de71c375982b87b86cd28d2bab35ece8285abe3b0aac57604dfc5a",
    },
    ["0.10.4"] = {
        "nvim-linux-x86_64",
        "95aaa8e89473f5421114f2787c13ae0ec6e11ebbd1a13a1bd6fcf63420f8073f",
    },
    ["0.11.7"] = {
        "nvim-linux-x86_64",
        "38a7c6317f94503841096c00e8fde05ef04b9472fc9d7d62b6e033cecd6f7991",
    },
    ["0.12.5"] = {
        "nvim-linux-x86_64",
        "bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875",
    },
}

local PROBE = table.concat({
    "local v=vim.version();",
    "local version=string.format('%d.%d.%d',v.major,v.minor,v.patch);",
    "assert(version=='@VERSION@');",
    "assert(type(vim.schedule)=='function' and type(vim.system)=='function');",
    "assert(type(vim.uv.hrtime)=='function' and type(vim.uv.new_timer)=='function');",
    "io.stdout:write(vim.json.encode({version=version,reported_prerelease=v.prerelease or false,",
    "lua=_VERSION,jit=jit and jit.version or false,libuv=vim.uv.version_string()}),'\\n')",
}, " ")

--- Environment names a probe must not inherit from the developer's Neovim or Lua setup.
local function probe_environment(directory)
    local env = {}
    for _, name in ipairs({ "CONFIG", "CACHE", "DATA", "STATE" }) do
        env["XDG_" .. name .. "_HOME"] = directory .. "/" .. name:lower()
    end
    return {
        env = env,
        unset = {
            "LUA_PATH",
            "LUA_CPATH",
            "LUA_INIT",
            "VIM",
            "VIMRUNTIME",
            "NVIM",
            "NVIM_LOG_FILE",
        },
    }
end

---@param executable string
---@param version string
function M.probe(executable, version)
    local directory =
        shell.check({ "mktemp", "-d", "/tmp/libtmux-lua-nvim-probe-XXXXXX" }):match("%S+")
    local opts = probe_environment(directory)
    local ok, report = pcall(function()
        local first = shell.check({ executable, "--version" }, opts):match("[^\n]+")
        if first ~= "NVIM v" .. version then
            error("Neovim executable does not match version " .. version, 0)
        end
        local output = shell.check({
            executable,
            "--headless",
            "-u",
            "NONE",
            "-i",
            "NONE",
            "-n",
            "-c",
            "lua " .. PROBE:gsub("@VERSION@", version),
            "-c",
            "qa!",
        }, opts)
        local decoded, parsed = pcall(json.decode, output)
        if not decoded or parsed.version ~= version then
            error("Neovim headless probe failed: " .. output:gsub("%s+$", ""), 0)
        end
        return parsed
    end)
    shell.run({ "rm", "-rf", directory })
    if not ok then
        error(report, 0)
    end
    return report
end

---@param version string
---@param check_only boolean
function M.bootstrap(version, check_only)
    local flavor, checksum = M.RELEASES[version][1], M.RELEASES[version][2]
    local asset = flavor .. ".tar.gz"
    local url = ("https://github.com/neovim/neovim/releases/download/v%s/%s"):format(version, asset)
    local source = repo.root .. "/.cache/source/nvim-" .. version
    local archive = source .. "/" .. asset
    local prefix = repo.root .. "/.cache/toolchains/nvim-" .. version
    local executable = prefix .. "/bin/nvim"
    local receipt = prefix .. "/.libtmux-host.json"
    if not files.exists(archive) then
        if check_only then
            error("Missing cached Neovim archive for " .. version .. "; run bootstrap", 0)
        end
        shell.check({ "mkdir", "-p", source })
        local partial = archive .. ".partial"
        shell.check(runtimes.download_command(url, partial))
        if runtimes.sha256(partial) ~= checksum then
            shell.run({ "rm", "-f", partial })
            error("SHA256 mismatch for Neovim " .. version, 0)
        end
        shell.check({ "mv", partial, archive })
    end
    if runtimes.sha256(archive) ~= checksum then
        error("Cached artifact SHA256 mismatch for Neovim " .. version, 0)
    end
    local expected = {
        version = version,
        platform = "Linux-x86_64",
        artifact_url = url,
        artifact_sha256 = checksum,
    }
    local installed = false
    if not files.exists(executable) then
        if check_only then
            error("Missing cached Neovim host for " .. version .. "; run bootstrap", 0)
        end
        local parent = prefix:match("^(.*)/[^/]+$")
        local staging =
            shell.check({ "mktemp", "-d", parent .. "/nvim-" .. version .. "-XXXXXX" }):match("%S+")
        shell.check({ "tar", "-xzf", archive, "-C", staging })
        if not files.exists(staging .. "/" .. flavor .. "/bin/nvim") then
            shell.run({ "rm", "-rf", staging })
            error("Neovim " .. version .. " archive lacks its expected executable", 0)
        end
        shell.check({ "mv", staging .. "/" .. flavor, prefix })
        shell.run({ "rm", "-rf", staging })
        installed = true
    end
    local ok, record = pcall(function()
        local executable_hash = runtimes.sha256(executable)
        if not installed then
            local stored = json.read(receipt)
            for key, value in pairs(expected) do
                if stored[key] ~= value then
                    error("Neovim " .. version .. " cache receipt differs from the artifact pin", 0)
                end
            end
            if stored.executable_sha256 ~= executable_hash then
                error("Neovim " .. version .. " executable changed since installation", 0)
            end
        end
        local host = M.probe(executable, version)
        local result = json.object({
            "version",
            "platform",
            "artifact_url",
            "artifact_sha256",
            "executable_sha256",
            "host",
        }, {
            version = version,
            platform = expected.platform,
            artifact_url = url,
            artifact_sha256 = checksum,
            executable_sha256 = executable_hash,
            host = host,
        })
        if installed then
            files.write(receipt, json.encode(result, 2) .. "\n")
        end
        return result
    end)
    if not ok then
        if installed then
            shell.run({ "rm", "-rf", prefix })
        end
        error(record, 0)
    end
    return record
end

--- Installs or checks each named host and prints one JSON report per host. Returns the exit code.
---@param versions string[]
---@param check_only boolean
---@return integer
function M.main(versions, check_only)
    if #versions == 0 then
        error("usage: bootstrap.lua hosts VERSION... [--check]", 0)
    end
    for _, version in ipairs(versions) do
        if not M.RELEASES[version] then
            error("Unknown Neovim version: " .. version, 0)
        end
    end
    local host = shell.check({ "uname", "-sm" }):match("^(.-)%s*$")
    if host ~= "Linux x86_64" then
        error("No pinned Neovim bootstrap artifact for this host; matrix cell remains untested", 0)
    end
    local failures, started = 0, os.time()
    for _, version in ipairs(versions) do
        local cell_started = os.time()
        local ok, report = pcall(M.bootstrap, version, check_only)
        if ok then
            report.executable = repo.root .. "/.cache/toolchains/nvim-" .. version .. "/bin/nvim"
            report.status = "READY"
            report.bootstrap_seconds = os.time() - cell_started
            local keys = json.keys(report)
            keys[#keys + 1], keys[#keys + 2], keys[#keys + 3] =
                "executable", "status", "bootstrap_seconds"
        else
            failures = failures + 1
            report = { version = version, status = "UNTESTED", error = tostring(report) }
            report.bootstrap_seconds = os.time() - cell_started
        end
        print(json.encode(report))
    end
    print(json.encode({ bootstrap_seconds = os.time() - started, unready_hosts = failures }))
    return failures > 0 and 1 or 0
end

return M
