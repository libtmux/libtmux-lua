local json = require("support.json")
local repo = require("support.repo")

local M = {}

M.MANIFEST = repo.root .. "/data/ci-matrix.json"
M.CATALOG = repo.root .. "/data/tmux-options.json"

M.SCOPES = { "edges", "full", "custom" }
M.EVENT_SCOPES = {
    push = "edges",
    pull_request = "edges",
    workflow_dispatch = "edges",
    schedule = "full",
}
M.TMATE_MODES = { "off", "before-tests", "on-failure" }
M.RUNNERS = { "ubuntu-24.04", "ubuntu-latest", "ubuntu-22.04" }

-- A mistyped list should fail rather than fan out into a huge matrix.
M.MAX_CUSTOM_LEGS = 12

-- The plan and the required check, which every run has.
M.FIXED_JOBS = 2

M.PLAN_JOB = "plan"
M.MATRIX_JOB = "validate"

-- Every rule below calls its siblings through `M`, so a test can replace one rule.

M.PlanError = {}
M.PlanError.__index = M.PlanError
M.PlanError.__tostring = function(self)
    return self.message
end

local function refuse(template, ...)
    error(setmetatable({ message = template:format(...) }, M.PlanError), 0)
end

-- A string as the error messages quote it: single quotes, or double quotes when it holds only a
-- single quote, with control characters and the quote mark escaped.
local function quote(text)
    local mark = (text:find("'", 1, true) and not text:find('"', 1, true)) and '"' or "'"
    local escaped = text:gsub("[%c\\" .. mark .. "]", function(char)
        local named = { ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return named[char] or (char == mark and "\\" .. char) or ("\\x%02x"):format(char:byte())
    end)
    return mark .. escaped .. mark
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

local function join(list)
    return table.concat(list, ", ")
end

local function extend(list, more)
    for _, item in ipairs(more) do
        list[#list + 1] = item
    end
    return list
end

function M.check_ref(ref)
    if #ref < 1 or #ref > 64 or ref:find("[^A-Za-z0-9._/%-]") then
        refuse("tmux ref %s must match ^[A-Za-z0-9._/-]{1,64}$", quote(ref))
    end
    if ref:sub(1, 1) == "-" or ref:find("..", 1, true) or ref:find("/$") or ref:find("%.lock$") then
        refuse("tmux ref %s is not a usable git ref", quote(ref))
    end
    if #ref >= 7 and #ref <= 39 and not ref:find("[^0-9a-f]") then
        refuse("tmux ref %s looks like an abbreviated commit; give all 40 hex digits", quote(ref))
    end
    return ref
end

-- Sorts the catalog's releases into released and development, and keeps the revision that pins
-- each development build, which is a moving name in the manifest.
function M.combine(manifest, catalog)
    local names = json.keys(catalog.releases)
    local revisions = {}
    for _, name in ipairs(json.keys(manifest.development)) do
        local release = catalog.releases[name]
        if release == nil then
            refuse("development build %s is not in the catalog", name)
        end
        ---@cast release -nil
        if type(release.revision) ~= "string" then
            refuse("development build %s has no revision in the catalog", name)
        end
        revisions[name] = release.revision
    end
    local released = {}
    for _, name in ipairs(names) do
        if manifest.development[name] == nil then
            released[#released + 1] = name
        end
    end
    if #released == 0 then
        refuse("the catalog has no released version")
    end
    local combined = { table = names, released = released, revisions = revisions }
    for key, value in pairs(manifest) do
        combined[key] = value
    end
    return combined
end

function M.load(manifest_path, catalog_path)
    return M.combine(json.read(manifest_path or M.MANIFEST), json.read(catalog_path or M.CATALOG))
end

function M.split_list(value)
    local items, seen = {}, {}
    for each in (value .. ","):gmatch("([^,]*),") do
        local item = each:match("^%s*(.-)%s*$")
        if item ~= "" and not seen[item] then
            seen[item] = true
            items[#items + 1] = item
        end
    end
    return items
end

function M.resolve_scope(event, scope)
    if scope ~= "" then
        if not contains(M.SCOPES, scope) then
            refuse("scope must be one of %s, not %s", join(M.SCOPES), quote(scope))
        end
        return scope
    end
    if M.EVENT_SCOPES[event] then
        return M.EVENT_SCOPES[event]
    end
    refuse("no scope is defined for the %s event", quote(event))
end

function M.check_scope_inputs(scope, tmux_ref)
    if tmux_ref ~= "" and scope ~= "custom" then
        refuse("tmux-ref is only used with scope custom")
    end
end

function M.edge_versions(released)
    local oldest, newest = released[1], released[#released]
    return oldest == newest and { oldest } or { oldest, newest }
end

function M.custom_refs(tmux_ref)
    local items = M.split_list(tmux_ref)
    if #items == 0 then
        refuse("scope custom needs tmux-ref, a comma-separated list of tmux refs")
    end
    local refs = {}
    for _, item in ipairs(items) do
        refs[#refs + 1] = M.check_ref(item)
    end
    return refs
end

function M.select_stack(requested, allowed, default, label)
    local chosen = M.split_list(requested)
    for _, item in ipairs(chosen) do
        if not contains(allowed, item) then
            refuse("%s must name versions from %s, not %s", label, join(allowed), quote(item))
        end
    end
    return #chosen > 0 and chosen or { default }
end

function M.choose_image(image)
    if image == "" then
        return M.RUNNERS[1]
    end
    if not contains(M.RUNNERS, image) then
        refuse("os must be one of %s, not %s", join(M.RUNNERS), quote(image))
    end
    return image
end

local CELL_KEYS = { "name", "gate", "lua", "tmux", "nvim", "client", "build", "ref", "tmate" }

function M.cell(fields)
    local cell = { tmux = "", nvim = "", client = "", build = "", ref = "", tmate = "off" }
    for key, value in pairs(fields) do
        cell[key] = value
    end
    return json.object(CELL_KEYS, cell)
end

-- What the build-tmux action is given for a table entry: a release name builds as itself, and a
-- development build is pinned to the revision the catalog recorded.
function M.pinned_ref(manifest, version)
    return manifest.revisions[version] or version
end

function M.unit_cells(manifest)
    local cells = {}
    for _, lua in ipairs(manifest.unit) do
        local name = lua == "luajit" and "Unit LuaJIT"
            or "Unit Lua " .. (lua:match("^[^.]+%.[^.]+") or lua)
        cells[#cells + 1] = M.cell({ name = name, gate = "unit", lua = lua })
    end
    return cells
end

-- A push runs both outer jobs on the edge releases. The full scope keeps the current one on the
-- release the manifest pins it to.
function M.outer_cells(manifest, scope, oldest, newest)
    local current = newest
    if scope == "full" then
        current = manifest.outer.current.full_tmux or newest
    end
    local cells = {}
    for _, role in ipairs({ "floor", "current" }) do
        local tmux = role == "floor" and oldest or current
        cells[#cells + 1] = M.cell({
            name = "Outer " .. role,
            gate = "outer",
            lua = manifest.outer[role].lua,
            tmux = tmux,
            nvim = manifest.outer[role].nvim,
            build = "pinned",
            ref = M.pinned_ref(manifest, tmux),
        })
    end
    return cells
end

function M.tmux_cells(manifest, versions, luas, nvims)
    local cells = {}
    for _, version in ipairs(versions) do
        local refused = manifest.refused[version]
        local gate, client, label, build, ref
        if refused then
            gate, build, label, ref = "refusal", "pinned", "tmux " .. version .. " refused", version
            client = refused.old_daemon and manifest.released[1] or ""
        elseif contains(manifest.table, version) then
            gate, client, label, build = "integration", "", "tmux " .. version, "pinned"
            ref = M.pinned_ref(manifest, version)
        else
            gate, client, label, build, ref = "integration", "", "tmux " .. version, "ref", version
        end
        for _, lua in ipairs(luas) do
            for _, nvim in ipairs(nvims) do
                local stack = {}
                if lua ~= manifest.stack.lua then
                    stack[#stack + 1] = "Lua " .. lua
                end
                if nvim ~= manifest.stack.nvim then
                    stack[#stack + 1] = "Neovim " .. nvim
                end
                cells[#cells + 1] = M.cell({
                    name = #stack > 0 and label .. " (" .. join(stack) .. ")" or label,
                    gate = gate,
                    lua = lua,
                    tmux = version,
                    nvim = nvim,
                    client = client,
                    build = build,
                    ref = ref,
                })
            end
        end
    end
    return cells
end

function M.require_cells(cells)
    if #cells == 0 then
        refuse("the plan has no job")
    end
end

function M.assign_tmate(event, mode, cells)
    if not contains(M.TMATE_MODES, mode) then
        refuse("tmate must be one of %s, not %s", join(M.TMATE_MODES), quote(mode))
    end
    if mode == "off" then
        return
    end
    if event ~= "workflow_dispatch" then
        refuse("tmate is only available on a workflow_dispatch run")
    end
    if #cells ~= 1 then
        refuse(
            "tmate needs exactly one job and this run has %d; "
                .. "use scope custom with one tmux-ref, lua and nvim",
            #cells
        )
    end
    cells[1].tmate = mode
end

-- `inputs` holds event, scope, tmux_ref, lua, nvim, image and tmate; all but event may be absent.
function M.plan(manifest, inputs)
    local event = inputs.event
    local chosen = M.resolve_scope(event, inputs.scope or "")
    M.check_scope_inputs(chosen, inputs.tmux_ref or "")
    local runner = M.choose_image(inputs.image or "")
    local luas = M.select_stack(inputs.lua or "", manifest.unit, manifest.stack.lua, "lua")
    local nvims = M.select_stack(inputs.nvim or "", manifest.nvim, manifest.stack.nvim, "nvim")
    local edges = M.edge_versions(manifest.released)

    local cells
    if chosen == "custom" then
        local versions = M.custom_refs(inputs.tmux_ref or "")
        local legs = #versions * #luas * #nvims
        if legs > M.MAX_CUSTOM_LEGS then
            refuse(
                "this run would have %d jobs; at most %d fit a custom run",
                legs,
                M.MAX_CUSTOM_LEGS
            )
        end
        cells = M.tmux_cells(manifest, versions, luas, nvims)
    else
        cells = M.unit_cells(manifest)
        extend(cells, M.outer_cells(manifest, chosen, edges[1], edges[#edges]))
        if chosen == "full" then
            extend(cells, M.tmux_cells(manifest, json.keys(manifest.refused), luas, nvims))
            extend(cells, M.tmux_cells(manifest, manifest.table, luas, nvims))
        else
            extend(cells, M.tmux_cells(manifest, edges, luas, nvims))
        end
    end
    M.require_cells(cells)
    local tmate = inputs.tmate
    M.assign_tmate(event, (tmate == nil or tmate == "") and "off" or tmate, cells)

    return json.object({ "scope", "os", "matrix", "expected_jobs" }, {
        scope = chosen,
        os = runner,
        matrix = json.object({ "include" }, { include = cells }),
        expected_jobs = M.FIXED_JOBS + #cells,
    })
end

function M.job_names(result)
    local names = { [M.PLAN_JOB] = true, required = true }
    for _, each in ipairs(result.matrix.include) do
        names[each.name] = true
    end
    return names
end

function M.check_needs(needs)
    local problems = {}
    for _, job in ipairs({ M.PLAN_JOB, M.MATRIX_JOB }) do
        local entry = needs[job]
        local result = type(entry) == "table" and entry.result or nil
        if result ~= "success" then
            local shown = (type(result) == "string" and result ~= "") and result or "missing"
            problems[#problems + 1] = ("%s finished %s, not success"):format(job, shown)
        end
    end
    return problems
end

function M.summary(result)
    local lines = {
        "### CI plan: " .. result.scope,
        "",
        "Expected jobs in this workflow: " .. result.expected_jobs,
        "",
    }
    for _, each in ipairs(result.matrix.include) do
        lines[#lines + 1] = "- " .. each.name
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Single-line workflow outputs as ordered {name, value} pairs.
function M.outputs(result)
    return {
        { "scope", result.scope },
        { "os", result.os },
        { "matrix", json.encode(result.matrix) },
        { "expected_jobs", tostring(result.expected_jobs) },
    }
end

return M
