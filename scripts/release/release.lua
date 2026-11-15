-- Prepare and validate explicit LuaRocks release versions without publishing.
local files = require("support.files")
local fs = require("support.fs")
local json = require("support.json")
local runtime = require("support.runtime")
local shell = require("support.shell")

local M = {}

M.REPOSITORY = "https://github.com/libtmux/libtmux-lua.git"
M.CHANGELOGS = { libtmux = "CHANGES.md" }

local function refuse(message)
    error(message, 0)
end

local function number(text)
    return text:match("^%d+$") ~= nil and (text == "0" or text:sub(1, 1) ~= "0")
end

--- Splits MAJOR.MINOR.PATCH[alphaN|betaN|rcN]-REVISION into its source version and revision.
---@param version any
---@return string source
---@return number revision
function M.identity(version)
    local major, minor, patch, prerelease, revision = tostring(
        type(version) == "string" and version or ""
    ):match("^(%d+)%.(%d+)%.(%d+)(%a*%d*)%-(%d+)$")
    local valid = major
        and number(major)
        and number(minor)
        and number(patch)
        and revision:sub(1, 1) ~= "0"
        and (
            prerelease == ""
            or prerelease:match("^alpha[1-9]%d*$")
            or prerelease:match("^beta[1-9]%d*$")
            or prerelease:match("^rc[1-9]%d*$")
        )
    if not valid then
        refuse("version must be MAJOR.MINOR.PATCH[alphaN|betaN|rcN]-REVISION")
    end
    return major .. "." .. minor .. "." .. patch .. prerelease, assert(tonumber(revision))
end

--- The rock version release.json names.
---@param root string
---@return string
function M.candidate(root)
    local metadata = json.read(root .. "/release.json")
    local keys = json.keys(metadata)
    table.sort(keys)
    if table.concat(keys, ",") ~= "package,version" or metadata.package ~= "libtmux" then
        refuse("release.json must identify the libtmux core only")
    end
    M.identity(metadata.version)
    return metadata.version
end

local function lines_of(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

--- Whether `heading` is a line of its own outside every code fence. A fence closes on a line of
--- the same character, at least as long, with no info string, so a shorter or different fence
--- inside one does not end it.
---@param markdown string
---@param heading string
---@return boolean
function M.has_heading(markdown, heading)
    local fence
    for _, line in ipairs(lines_of(markdown)) do
        local marks, info = line:match("^%s*(````*)(.*)$")
        if not marks then
            marks, info = line:match("^%s*(~~~~*)(.*)$")
        end
        if fence == nil then
            if marks then
                fence = marks
            elseif line == heading then
                return true
            end
        elseif
            marks
            and marks:sub(1, 1) == fence:sub(1, 1)
            and #marks >= #fence
            and not info:find("%S")
        then
            fence = nil
        end
    end
    return false
end

--- Each way a rock's changelog falls short of the policy: the file exists, it opens with the name
--- of the rock it belongs to, and it has an Unreleased section for the next release.
---@param root string
---@return string[]
function M.changelog_failures(root)
    local failures = {}
    local names = {}
    for name in pairs(M.CHANGELOGS) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local path = M.CHANGELOGS[name]
        if not fs.is_file(root .. "/" .. path) then
            failures[#failures + 1] = path .. ": " .. name .. " has no changelog"
        else
            local text = files.read(root .. "/" .. path)
            local opened = text:match("^# Changelog%s+Notable changes to `([^`]+)`%.\n")
                or text:match("^# Changelog%s+Notable changes to `([^`]+)`%.$")
            if not opened then
                failures[#failures + 1] = path
                    .. ': does not open with "Notable changes to `'
                    .. name
                    .. '`."'
            elseif opened ~= name then
                failures[#failures + 1] = path
                    .. ": is the changelog of "
                    .. opened
                    .. ", not "
                    .. name
            end
            if not M.has_heading(text, "## Unreleased") then
                failures[#failures + 1] = path .. ': has no "## Unreleased" section'
            end
        end
    end
    return failures
end

local function command(argv, cwd)
    local code, output = shell.run(argv, { cwd = cwd, unset = runtime.LUA_VARIABLES })
    if code ~= 0 then
        refuse(output:match("^%s*(.-)%s*$"))
    end
    return output
end

--- The versioned rockspec LuaRocks makes from the development one, formatted by StyLua.
---@param root string
---@param version string
---@return string
function M.prepared_spec(root, version)
    local source = M.identity(version)
    local directory = fs.mkdtemp("libtmux-lua-version-")
    local ok, text = pcall(function()
        command({
            "luarocks",
            "new_version",
            root .. "/rockspecs/libtmux-scm-1.rockspec",
            version,
            "--tag",
            "v" .. source,
            "--dir",
            directory,
        }, directory)
        local path = directory .. "/libtmux-" .. version .. ".rockspec"
        local argv = { "stylua", "--syntax", "Lua51" }
        if fs.is_file(root .. "/stylua.toml") then
            argv[#argv + 1] = "--config-path"
            argv[#argv + 1] = root .. "/stylua.toml"
        end
        argv[#argv + 1] = path
        command(argv, root)
        return files.read(path)
    end)
    fs.remove_tree(directory)
    if not ok then
        error(text, 0)
    end
    return text
end

--- CHANGES.md with the Unreleased entries filed under the version's heading.
---@param notes string
---@param version string
---@return string
function M.release_notes(notes, version)
    local heading = "## " .. version .. "\n"
    for _, line in ipairs(lines_of(notes)) do
        if
            line == "## " .. version
            or line:match("^## " .. version:gsub("%p", "%%%0") .. " %(%d%d%d%d%-%d%d%-%d%d%)$")
        then
            return notes
        end
    end
    local marker = "## Unreleased\n"
    local first, last = notes:find(marker, 1, true)
    if not first then
        refuse("CHANGES.md needs an Unreleased section")
    end
    local before, after = notes:sub(1, first - 1), notes:sub(last + 1)
    local split_start, split_end = after:find("\n## ", 1, true)
    local entry = split_start and after:sub(1, split_start - 1) or after
    local older = split_start and after:sub(split_end + 1)
    if not entry:find("%S") then
        refuse("add release notes under Unreleased before preparing a version")
    end
    return before
        .. marker
        .. "\n"
        .. heading
        .. "\n"
        .. entry:match("^%s*(.-)%s*$")
        .. "\n"
        .. (older and "\n## " .. older or "")
end

--- Brings release.json, the runtime version, the release rockspec and the changelog in line with
--- `version`, or with `check` only reports the drift.
---@param root string
---@param version string
---@param check? boolean
---@return string
function M.prepare(root, version, check)
    local source = M.identity(version)
    local spec = "rockspecs/libtmux-" .. version .. ".rockspec"
    local expected = {
        {
            "release.json",
            json.encode(
                json.object({ "package", "version" }, { package = "libtmux", version = version }),
                2
            ) .. "\n",
        },
        { "lua/libtmux/init.lua", ('return { _VERSION = "%s" }\n'):format(source) },
        { spec, M.prepared_spec(root, version) },
        { "CHANGES.md", M.release_notes(files.read(root .. "/CHANGES.md"), version) },
    }
    local changed, names = {}, {}
    for _, row in ipairs(expected) do
        local path = root .. "/" .. row[1]
        if not fs.is_file(path) or files.read(path) ~= row[2] then
            changed[#changed + 1] = row
            names[#names + 1] = row[1]
        end
    end
    if check and #changed > 0 then
        refuse("release metadata drift: " .. table.concat(names, ", "))
    end
    if #changed > 0 and not check then
        local tagged = shell.run(
            { "git", "rev-parse", "--verify", "refs/tags/v" .. source },
            { cwd = root }
        ) == 0
        if tagged and fs.is_file(root .. "/" .. spec) then
            for _, row in ipairs(changed) do
                if row[1] == spec then
                    refuse("tagged release rockspec would change; use a new rockspec revision")
                end
            end
        end
        for _, row in ipairs(changed) do
            files.write(root .. "/" .. row[1], row[2])
        end
    end
    return version
end

---@param version string
---@return string
function M.release_tag(version)
    local source, revision = M.identity(version)
    return revision == 1 and "v" .. source or "rocks/" .. version
end

--- Checks that retained artifacts are the ones the validated release job made.
---@param root string
---@param directory string
---@param head string
function M.verify_artifacts(root, directory, head)
    local version = M.candidate(root)
    local manifest = json.read(directory .. "/candidate.json")
    if
        not (
            manifest.package == "libtmux"
            and manifest.version == version
            and manifest.head == head
            and manifest.dirty == false
            and manifest.source == "public-tag"
        )
    then
        refuse("artifacts must come from this clean release commit and the public source tag")
    end
    local names = { "libtmux-" .. version .. ".rockspec", "libtmux-" .. version .. ".src.rock" }
    local listed = manifest.artifacts and json.keys(manifest.artifacts) or {}
    table.sort(listed)
    table.sort(names)
    if table.concat(listed, ",") ~= table.concat(names, ",") then
        refuse("release artifact inventory mismatch")
    end
    local sums = {}
    for _, name in ipairs(json.keys(manifest.artifacts)) do
        local digest = manifest.artifacts[name]
        if shell.sha256(directory .. "/" .. name) ~= digest then
            refuse("artifact checksum mismatch: " .. name)
        end
        sums[#sums + 1] = digest .. "  " .. name .. "\n"
    end
    local spec_name = "libtmux-" .. version .. ".rockspec"
    if
        files.read(directory .. "/" .. spec_name) ~= files.read(root .. "/rockspecs/" .. spec_name)
    then
        refuse("artifact rockspec differs from the reviewed release rockspec")
    end
    if files.read(directory .. "/SHA256SUMS") ~= table.concat(sums) then
        refuse("SHA256SUMS differs from the validated artifacts")
    end
end

---@param root string
---@param event table The GitHub tag-push event.
---@param commit string
---@param artifacts? string
function M.verify_release(root, event, commit, artifacts)
    local failures = M.changelog_failures(root)
    if #failures > 0 then
        refuse("every rock needs a changelog:\n" .. table.concat(failures, "\n"))
    end
    local version = M.candidate(root)
    local source, revision = M.identity(version)
    local repository = type(event.repository) == "table" and event.repository.full_name or nil
    if
        repository ~= "libtmux/libtmux-lua"
        or event.ref ~= "refs/tags/" .. M.release_tag(version)
        or event.deleted ~= false
    then
        refuse("publication requires a canonical version-tag push")
    end
    local head = command({ "git", "rev-parse", "HEAD" }, root):match("%S+")
    local tagged = command(
        { "git", "rev-parse", "refs/tags/" .. M.release_tag(version) .. "^{commit}" },
        root
    ):match("%S+")
    if head ~= commit or tagged ~= head then
        refuse("release tag, checkout and tested commit differ")
    end
    if command({ "git", "status", "--porcelain" }, root):find("%S") then
        refuse("release checkout must be clean")
    end
    if
        shell.run(
            { "git", "merge-base", "--is-ancestor", head, "refs/remotes/origin/master" },
            { cwd = root }
        ) ~= 0
    then
        refuse("release commit must be on origin/master")
    end
    if
        revision > 1
        and shell.run(
                { "git", "merge-base", "--is-ancestor", "refs/tags/v" .. source, head },
                { cwd = root }
            )
            ~= 0
    then
        refuse("packaging revision must descend from its immutable source tag")
    end
    if artifacts then
        M.verify_artifacts(root, artifacts, head)
    end
end

return M
