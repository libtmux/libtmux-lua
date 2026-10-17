local t = require("luaunit")
local fields = require("libtmux._internal.fields")
local registry = require("libtmux._internal.support.capabilities")
local M = {}

local function ids_of(list)
    local seen = {}
    for _, entry in ipairs(list) do
        t.assertStrMatches(entry.id, "^[a-z][a-z0-9]*[a-z0-9-]*$")
        t.assertNil(seen[entry.id], entry.id)
        seen[entry.id] = true
        t.assertTrue(#entry.name > 0 and #entry.summary > 0, entry.id)
        t.assertTrue(#entry.apis > 0 and #entry.commands > 0, entry.id)
    end
    return seen
end

function M.test_ids_are_unique_across_capabilities_and_workarounds()
    local capabilities = ids_of(registry.capabilities)
    for id in pairs(ids_of(registry.workarounds)) do
        t.assertNil(capabilities[id], id)
    end
end

function M.test_every_release_is_one_the_library_can_place()
    local floor = fields.support_floor
    for _, entry in ipairs(registry.capabilities) do
        t.assertTrue(fields.at_least(entry.since, floor), entry.id)
        t.assertTrue(entry.handling ~= "refuse" or entry.error ~= nil, entry.id)
    end
    for _, entry in ipairs(registry.workarounds) do
        for _, release in ipairs(entry.releases) do
            t.assertTrue(fields.at_least(release, floor), entry.id)
        end
        t.assertTrue(entry.required == nil or fields.at_least(entry.required, floor), entry.id)
    end
end

function M.test_the_committed_manifest_is_the_registry()
    local render = assert(loadfile("scripts/emit_capabilities.lua"))
    local expected = render("render")
    local file = assert(io.open("capabilities.json", "rb"))
    local committed = file:read("*a")
    file:close()
    t.assertEquals(committed, expected, "capabilities.json differs from the registry")
end

function M.test_lookup_rejects_an_unknown_id()
    t.assertEquals(registry.since("control-mode"), "3.7")
    t.assertError(registry.since, "no-such-capability")
    t.assertError(registry.workaround, "control-mode")
end

return M
