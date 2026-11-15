-- Typed options and hook programs against owned servers under both runtime hosts.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local M = {}

local function run_case(mode, host)
    fixture.with({ env = { LC_ALL = "C", LANG = "C" } }, function(f)
        local result = f:program(host, "settings", {
            TMUX_DAEMON_VERSION = f:version(),
            LIBTMUX_SETTINGS_CASE = mode,
        })
        test.assertStrContains(result.stdout, ("public settings %s PASS"):format(mode))
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:out("list-clients"), "")
        test.assertEquals(f:try("has-session", "-t", "$0").code, 0)
    end)
end

local cases = {
    scalar_bytes = "scalar_bytes_absence_and_copied_results",
    scalar_scopes = "scalar_scope_inheritance_and_false",
    arrays = "sparse_arrays_indexed_append_empty_and_unset",
    hook_storage = "hook_storage_canonical_reads_and_inheritance",
    hook_execution = "literal_and_custom_hook_execution",
}
for mode, name in pairs(cases) do
    fixture.each_host(M, name, function(host)
        run_case(mode, host)
    end)
end

return M
