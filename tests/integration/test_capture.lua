-- Capture native byte modes and clear history on isolated pane processes.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local repo = require("support.repo")
local M = {}

local CAPTURE = repo.root .. "/tests/support/programs/capture.lua"

local function run_case(case, host)
    fixture.with(function(f)
        local named = case:match("^buffer_")
        if named then
            f:run("set-buffer", "-b", "unrelated", "unchanged")
            f:run("set-buffer", "-b", "kept", "unchanged")
            f:run("set-buffer", "-b", "screen", "old")
        end
        local untouched = f:out("capture-pane", "-p", "-t", "%0")
        local result = f:program(host, "capture", {
            LIBTMUX_CAPTURE_CASE = case,
            LIBTMUX_CAPTURE_SCRIPT = CAPTURE,
        })
        test.assertStrContains(result.stdout, "public capture/history PASS")
        local pane_id = result.stdout:gsub("%s+$", ""):match("(%S+)$")
        if case == "buffer_pending" then
            test.assertEquals(f:out("show-buffer", "-b", "literal#{pid}\\;"), "\27[")
            test.assertEquals(f:out("show-buffer", "-b", "escaped"), "\\033[")
        elseif case == "buffer_screen" then
            test.assertEquals(f:out("show-buffer", "-b", "kept"), "unchanged")
            test.assertNotEquals(f:try("show-buffer", "-b", "absent").code, 0)
            test.assertEquals(
                f:out("show-buffer", "-b", "screen"),
                f:out("capture-pane", "-p", "-S", "0", "-E", "0", "-t", pane_id)
            )
        end
        if named then
            test.assertEquals(f:out("show-buffer", "-b", "unrelated"), "unchanged")
        end
        test.assertEquals(f:out("capture-pane", "-p", "-t", "%0"), untouched)
        test.assertEquals(f:out("list-clients"), "")
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:try("has-session", "-t", "$0").code, 0)
    end)
end

local cases = {
    pending = "pending_escape_sequence_bytes",
    history = "history_metadata_and_explicit_clearing",
    buffer_pending = "named_capture_preserves_pending_bytes_without_print_newline",
    buffer_screen = "named_capture_empty_noop_and_screen_replacement",
}
for case, name in pairs(cases) do
    fixture.each_host(M, name, function(host)
        run_case(case, host)
    end)
end

return M
