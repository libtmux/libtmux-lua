-- The CI manifest, the tmux catalog, the bootstrap tables and the docs agree.
local test = require("luaunit")
local files = require("support.files")
local hosts = require("bootstrap.hosts")
local json = require("support.json")
local planner = require("ci_plan.planner")
local repo = require("support.repo")
local runtimes = require("bootstrap.runtimes")
local M = {}

local function squash(text)
    return (text:gsub("%s+", " "))
end

local function table_row(docs, component)
    return docs:match("\n| " .. component:gsub("%.", "%%.") .. " | (.-) |\n")
end

--- The two versions a document says a push tests, or nil.
local function stated_edges(text)
    local first, last = squash(text):match("oldest and newest released tmux %((%S+) and (%S+)%)")
    return first and { first, last }
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

--- Names each way the manifest and what it describes disagree.
local function problems(manifest, catalog_releases, docs, contributing)
    local found = {}
    local releases, released = catalog_releases, {}
    for _, name in ipairs(releases) do
        if manifest.development[name] == nil then
            released[#released + 1] = name
        end
    end
    local edges = #released > 0 and { released[1], released[#released] } or nil
    local documents = { { "compatibility page", docs }, { "contributor guide", contributing } }
    for _, entry in ipairs(documents) do
        local stated = stated_edges(entry[2])
        if not (stated and edges and stated[1] == edges[1] and stated[2] == edges[2]) then
            found[#found + 1] = "the "
                .. entry[1]
                .. " states other edges than the catalog's oldest and newest release"
        end
    end
    local unit = {}
    for _, name in ipairs(manifest.unit) do
        if name ~= "luajit" then
            unit[#unit + 1] = name
        end
    end
    if table_row(docs, "tmux") ~= table.concat(releases, ", ") then
        found[#found + 1] = "the docs tmux row differs from the catalog releases"
    end
    if table_row(docs, "PUC Lua") ~= table.concat(unit, ", ") then
        found[#found + 1] = "the docs PUC Lua row differs from the unit runtimes"
    end
    if table_row(docs, "Neovim") ~= table.concat(manifest.nvim, ", ") then
        found[#found + 1] = "the docs Neovim row differs from the manifest hosts"
    end
    for _, name in ipairs(json.keys(manifest.development)) do
        if not contains(releases, name) then
            found[#found + 1] = "development build " .. name .. " is not in the catalog"
        end
    end
    if #released == 0 then
        found[#found + 1] = "the catalog has no released version"
    end
    local pin = manifest.outer.current.full_tmux
    if pin ~= nil and not contains(releases, pin) then
        found[#found + 1] = "the full-scope outer pin " .. pin .. " is not in the catalog"
    end
    local refusal = ""
    for _, paragraph in ipairs(squash(docs):gmatch("[^\n]+") and { squash(docs) } or {}) do
        refusal = paragraph
    end
    for name, lane in pairs(manifest.refused) do
        if contains(releases, name) then
            found[#found + 1] = "refused release " .. name .. " is in the catalog"
        end
        if not lane.revision:match("^%x+$") or #lane.revision ~= 40 then
            found[#found + 1] = "refused release " .. name .. " has no full revision"
        end
        if not refusal:find("refusal lane", 1, true) or not refusal:find(name, 1, true) then
            found[#found + 1] = "the docs refusal lanes omit " .. name
        end
    end
    local buildable = { luajit = true }
    for version in pairs(runtimes.RELEASES) do
        buildable[version] = true
    end
    local wanted = { manifest.stack.lua }
    for _, name in ipairs(manifest.unit) do
        wanted[#wanted + 1] = name
    end
    for _, each in pairs(manifest.outer) do
        wanted[#wanted + 1] = each.lua
    end
    for _, name in ipairs(wanted) do
        if not buildable[name] then
            found[#found + 1] = "the manifest names a Lua runtime the bootstrap cannot build"
            break
        end
    end
    local hosts_wanted = { manifest.stack.nvim }
    for _, each in pairs(manifest.outer) do
        hosts_wanted[#hosts_wanted + 1] = each.nvim
    end
    for _, name in ipairs(manifest.nvim) do
        hosts_wanted[#hosts_wanted + 1] = name
    end
    for _, name in ipairs(hosts_wanted) do
        if not hosts.RELEASES[name] then
            found[#found + 1] = "the manifest names a Neovim host the bootstrap cannot install"
            break
        end
    end
    local accepted = true
    for _, name in ipairs({
        manifest.stack.nvim,
        manifest.outer.floor.nvim,
        manifest.outer.current.nvim,
    }) do
        accepted = accepted and contains(manifest.nvim, name)
    end
    if not accepted or not contains(manifest.unit, manifest.stack.lua) then
        found[#found + 1] = "the default stack is not one the dispatch inputs accept"
    end
    return found
end

local function has(list, message)
    for _, item in ipairs(list) do
        if item == message then
            return true
        end
    end
    return false
end

local manifest = json.read(repo.root .. "/data/ci-matrix.json")
local releases = json.keys(json.read(repo.root .. "/data/tmux-options.json").releases)
local docs = files.read(repo.root .. "/docs/compatibility.md")
local contributing = files.read(repo.root .. "/.github/CONTRIBUTING.md")
local STALE = "oldest and newest released tmux (3.3a and 3.7c)"
local EDGES = "oldest and newest released tmux (3.3a and 3.8)"

local function mutated()
    return copy(manifest)
end

function M.test_the_repository_agrees()
    test.assertEquals(problems(manifest, releases, docs, contributing), {})
end

function M.test_a_docs_row_that_drifts_is_reported()
    for _, row in ipairs({
        { "tmux", "3.8, next-3.9" },
        { "PUC Lua", "5.5.1" },
        { "Neovim", "0.12.5" },
    }) do
        local text = docs:gsub(
            "(\n| "
                .. row[1]:gsub("%.", "%%.")
                .. " | [^\n]-)"
                .. row[2]:gsub("[%.%-]", "%%%0")
                .. " |\n",
            "%1|\n"
        )
        test.assertNotEquals(text, docs, row[1])
        test.assertNotEquals(problems(manifest, releases, text, contributing), {}, row[1])
    end
end

function M.test_documents_that_state_stale_edges_are_reported()
    local message = "states other edges than the catalog's oldest and newest release"
    test.assertStrContains(docs, EDGES)
    test.assertStrContains(squash(contributing), EDGES)
    local stale_docs = docs:gsub(EDGES:gsub("[%.%(%)]", "%%%0"), STALE)
    test.assertTrue(
        has(
            problems(manifest, releases, stale_docs, contributing),
            "the compatibility page " .. message
        )
    )
    local stale_guide = squash(contributing):gsub(EDGES:gsub("[%.%(%)]", "%%%0"), STALE)
    test.assertTrue(
        has(problems(manifest, releases, docs, stale_guide), "the contributor guide " .. message)
    )
end

function M.test_a_development_build_outside_the_catalog_is_reported()
    local changed = mutated()
    changed.development["3.9"] = "release_3.9"
    test.assertTrue(
        has(
            problems(changed, releases, docs, contributing),
            "development build 3.9 is not in the catalog"
        )
    )
end

function M.test_an_outer_pin_outside_the_catalog_is_reported()
    local changed = mutated()
    changed.outer.current.full_tmux = "3.9"
    test.assertTrue(
        has(
            problems(changed, releases, docs, contributing),
            "the full-scope outer pin 3.9 is not in the catalog"
        )
    )
end

function M.test_a_refused_release_in_the_catalog_is_reported()
    local changed = mutated()
    changed.refused["3.4"] = { revision = string.rep("0", 40), old_daemon = false }
    test.assertTrue(
        has(
            problems(changed, releases, docs, contributing),
            "refused release 3.4 is in the catalog"
        )
    )
end

function M.test_a_short_refused_revision_is_reported()
    local changed = mutated()
    changed.refused["3.3"].revision = "87fe00e"
    test.assertTrue(
        has(
            problems(changed, releases, docs, contributing),
            "refused release 3.3 has no full revision"
        )
    )
end

function M.test_a_refusal_lane_the_docs_omit_is_reported()
    local changed = mutated()
    changed.refused["2.9"] = { revision = string.rep("0", 40), old_daemon = false }
    test.assertTrue(
        has(problems(changed, releases, docs, contributing), "the docs refusal lanes omit 2.9")
    )
end

function M.test_a_runtime_or_host_the_bootstrap_lacks_is_reported()
    local changed = mutated()
    changed.unit[#changed.unit + 1] = "5.6.0"
    test.assertTrue(
        has(
            problems(changed, releases, docs, contributing),
            "the manifest names a Lua runtime the bootstrap cannot build"
        )
    )
    changed = mutated()
    changed.nvim[#changed.nvim + 1] = "0.99.0"
    test.assertTrue(
        has(
            problems(changed, releases, docs, contributing),
            "the manifest names a Neovim host the bootstrap cannot install"
        )
    )
end

function M.test_a_default_stack_the_inputs_reject_is_reported()
    local changed = mutated()
    changed.stack.nvim = "0.10.4"
    test.assertTrue(
        has(
            problems(changed, releases, docs, contributing),
            "the default stack is not one the dispatch inputs accept"
        )
    )
end

function M.test_a_catalog_without_a_release_is_reported()
    local only_development = json.keys(manifest.development)
    test.assertTrue(
        has(
            problems(manifest, only_development, docs, contributing),
            "the catalog has no released version"
        )
    )
end

function M.test_the_planner_agrees_with_the_manifest_about_the_edges()
    local loaded = planner.load()
    test.assertEquals(planner.edge_versions(loaded.released), { releases[1], "3.8" })
end

return M
