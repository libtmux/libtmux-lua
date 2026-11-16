-- What the CI plan checks share: the manifest and catalog the plan is built from, the job list the
-- full scope has to produce, and the helpers that read a plan.
local test = require("luaunit")
local json = require("support.json")
local planner = require("ci_plan.planner")

local MANIFEST = planner.load()
local CATALOG = json.read(planner.CATALOG)
local RELEASED = MANIFEST.released
local DEVELOPMENT = {}
for _, name in ipairs(MANIFEST.table) do
    if MANIFEST.development[name] ~= nil then
        DEVELOPMENT[#DEVELOPMENT + 1] = name
    end
end
local REFUSED = json.keys(MANIFEST.refused)
local OLDEST, NEWEST = RELEASED[1], RELEASED[#RELEASED]
local UNIT = MANIFEST.unit

-- The jobs the full scope runs, in the workflow's order.
local FULL_SET = {
    { "Unit Lua 5.1", "unit", "5.1.5", "", "", "" },
    { "Unit Lua 5.2", "unit", "5.2.4", "", "", "" },
    { "Unit Lua 5.3", "unit", "5.3.6", "", "", "" },
    { "Unit Lua 5.4", "unit", "5.4.9", "", "", "" },
    { "Unit Lua 5.5", "unit", "5.5.1", "", "", "" },
    { "Unit LuaJIT", "unit", "luajit", "", "", "" },
    { "Outer floor", "outer", "5.1.5", "3.3a", "0.10.0", "" },
    { "Outer current", "outer", "5.5.1", "3.7c", "0.12.5", "" },
    { "tmux 3.0a refused", "refusal", "5.5.1", "3.0a", "0.12.5", "3.3a" },
    { "tmux 3.1c refused", "refusal", "5.5.1", "3.1c", "0.12.5", "3.3a" },
    { "tmux 3.2a refused", "refusal", "5.5.1", "3.2a", "0.12.5", "" },
    { "tmux 3.3 refused", "refusal", "5.5.1", "3.3", "0.12.5", "" },
    { "tmux 3.3a", "integration", "5.5.1", "3.3a", "0.12.5", "" },
    { "tmux 3.4", "integration", "5.5.1", "3.4", "0.12.5", "" },
    { "tmux 3.5", "integration", "5.5.1", "3.5", "0.12.5", "" },
    { "tmux 3.5a", "integration", "5.5.1", "3.5a", "0.12.5", "" },
    { "tmux 3.6", "integration", "5.5.1", "3.6", "0.12.5", "" },
    { "tmux 3.6a", "integration", "5.5.1", "3.6a", "0.12.5", "" },
    { "tmux 3.6b", "integration", "5.5.1", "3.6b", "0.12.5", "" },
    { "tmux 3.7", "integration", "5.5.1", "3.7", "0.12.5", "" },
    { "tmux 3.7a", "integration", "5.5.1", "3.7a", "0.12.5", "" },
    { "tmux 3.7b", "integration", "5.5.1", "3.7b", "0.12.5", "" },
    { "tmux 3.7c", "integration", "5.5.1", "3.7c", "0.12.5", "" },
    { "tmux 3.7d", "integration", "5.5.1", "3.7d", "0.12.5", "" },
    { "tmux 3.8", "integration", "5.5.1", "3.8", "0.12.5", "" },
    { "tmux next-3.9", "integration", "5.5.1", "next-3.9", "0.12.5", "" },
}

-- The rules as the module defines them, before any deliberate break.
local RULES = {}
for _, name in ipairs({
    "resolve_scope",
    "tmux_cells",
    "assign_tmate",
    "check_needs",
    "outer_cells",
    "unit_cells",
    "combine",
}) do
    RULES[name] = planner[name]
end

local function copy(source)
    local result = {}
    for key, value in pairs(source) do
        result[key] = value
    end
    return result
end

local function map(list, transform)
    local result = {}
    for index, item in ipairs(list) do
        result[index] = transform(item)
    end
    return result
end

local function filter(list, keep)
    local result = {}
    for _, item in ipairs(list) do
        if keep(item) then
            result[#result + 1] = item
        end
    end
    return result
end

local function set(list)
    local result = {}
    for _, item in ipairs(list) do
        result[item] = true
    end
    return result
end

local function field(name)
    return function(item)
        return item[name]
    end
end

local function cells(result)
    return result.matrix.include
end

local function gated(result, gate)
    return filter(cells(result), function(each)
        return each.gate == gate
    end)
end

local function tmux_of(result, gate)
    return map(gated(result, gate or "integration"), field("tmux"))
end

local function run(event, inputs)
    local all = copy(inputs or {})
    all.event = event
    return planner.plan(MANIFEST, all)
end

-- Runs `action` and fails the check unless it is refused with a message naming the problem.
local function raises(action, match)
    local ok, failure = pcall(action)
    if ok then
        test.fail("the plan was not refused: " .. match)
    end
    if getmetatable(failure) ~= planner.PlanError then
        error(failure, 0)
    end
    test.assertStrContains(failure.message, match)
end

local function refused(match, inputs)
    local all = copy(inputs or {})
    local event = all.event or "workflow_dispatch"
    raises(function()
        return run(event, all)
    end, match)
end

-- The manifest against a catalog that lists exactly `names`, each with a revision.
local function loaded(names, changes)
    local releases = {}
    for _, name in ipairs(names) do
        releases[name] = { revision = "revision-of-" .. name }
    end
    local manifest = json.read(planner.MANIFEST)
    for key, value in pairs(changes or {}) do
        manifest[key] = value
    end
    return planner.combine(manifest, { releases = json.object(names, releases) })
end

return {
    MANIFEST = MANIFEST,
    CATALOG = CATALOG,
    RELEASED = RELEASED,
    DEVELOPMENT = DEVELOPMENT,
    REFUSED = REFUSED,
    OLDEST = OLDEST,
    NEWEST = NEWEST,
    UNIT = UNIT,
    FULL_SET = FULL_SET,
    RULES = RULES,
    copy = copy,
    map = map,
    filter = filter,
    set = set,
    field = field,
    cells = cells,
    gated = gated,
    tmux_of = tmux_of,
    run = run,
    raises = raises,
    refused = refused,
    loaded = loaded,
}
