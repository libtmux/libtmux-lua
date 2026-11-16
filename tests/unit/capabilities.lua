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
    t.assertEquals(
        committed,
        expected,
        "capabilities.json differs from the registry; "
            .. "run lua scripts/emit_capabilities.lua > capabilities.json"
    )
end

function M.test_the_raw_break_pane_is_refused_and_only_break_out_repairs()
    local raw = registry.workaround("break-pane-misnames-windows")
    t.assertEquals(raw.handling, "refuse")
    t.assertItemsEquals(raw.apis, {
        "libtmux.Server:command",
        "libtmux.Server:batch",
        "libtmux.Server:group",
    })
    local repair = registry.workaround("break-out-rename-repair")
    t.assertEquals(repair.handling, "repair")
    t.assertEquals(repair.apis, { "libtmux.Pane:break_out" })
end

function M.test_json_layout_floor_is_the_3_8_release()
    t.assertEquals(registry.since("layout-json"), "3.8")
end

function M.test_lookup_rejects_an_unknown_id()
    t.assertEquals(registry.since("control-mode"), "3.7")
    t.assertError(registry.since, "no-such-capability")
    t.assertError(registry.workaround, "control-mode")
end

function M.test_reports_feature_boundaries_and_exact_release_workarounds()
    t.assertEquals(type(registry.report), "function", "capability reports are missing")
    for _, case in ipairs({
        { "3.3a", false, false },
        { "3.7", true, false },
        { "3.7z", true, false },
        { "next-3.8", true, false },
        { "3.8-rc2", true, false },
        { "3.8", true, true },
        { "3.8a", true, true },
    }) do
        local report = registry.report(case[1])
        t.assertEquals(report.version, case[1])
        t.assertEquals(report.features["control-mode"].supported, case[2], case[1])
        t.assertEquals(report.features["layout-json"].supported, case[3], case[1])
        t.assertEquals(report.features["layout-json"].since, "3.8")
        t.assertNil(report.features["no-such-capability"])
    end
    t.assertTrue(registry.report("3.7").workarounds["name-separators-rejected"].active)
    t.assertFalse(registry.report("3.7a").workarounds["name-separators-rejected"].active)
    t.assertNil(registry.report("3.7").workarounds["control-mode"])
end

function M.test_report_mutation_cannot_change_admission_or_another_report()
    t.assertEquals(type(registry.report), "function", "capability reports are missing")
    local report = registry.report("3.7")
    report.features["layout-json"].since = "1.0"
    report.features["layout-json"].supported = true
    report.features["control-mode"].commands[1].flags[1] = "broken"
    report.features["control-mode"].apis[1] = "broken"
    report.workarounds["name-separators-rejected"].releases[1] = "3.7a"
    local next_report = registry.report("3.7")
    t.assertEquals(next_report.features["layout-json"].since, "3.8")
    t.assertFalse(next_report.features["layout-json"].supported)
    t.assertEquals(next_report.features["control-mode"].commands[1].flags[1], "-E")
    t.assertEquals(next_report.features["control-mode"].apis[1], "libtmux.Server:observe")
    t.assertTrue(next_report.workarounds["name-separators-rejected"].active)
    local refusal = assert(require("libtmux._internal.features").commands("3.7", {
        { "select-layout", '{"type":"pane"}' },
    }))
    t.assertEquals(refusal.code, "unsupported")
    t.assertEquals(refusal.required, "3.8")
end

return M
