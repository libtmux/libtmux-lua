-- Binary buffer storage and native paste semantics through the public API.
local test = require("luaunit")
local fixture = require("tests.support.fixture")
local files = require("support.files")
local repo = require("support.repo")
local M = {}

local PAYLOAD = "A\0\1\27\127\255\nBENDMARK"
local PASTE = repo.root .. "/tests/support/programs/paste.lua"

local function run_case(mode, host)
    fixture.with({ env = { LC_ALL = "C", LANG = "C" } }, function(f)
        local version = f:version()
        local report = f.path .. "/paste.bin"
        local result = f:program(host, "buffer", {
            LIBTMUX_BUFFER_CASE = mode,
            LIBTMUX_BUFFER_SCRIPT = PASTE,
            LIBTMUX_BUFFER_REPORT = report,
        })
        test.assertStrContains(result.stdout, ("public buffer %s PASS"):format(mode))
        if mode == "raw" or mode == "bracket" or mode == "native" or mode == "separator" then
            local expected = PAYLOAD
            if mode == "bracket" then
                expected = "\27[200~" .. PAYLOAD .. "\27[201~"
            elseif mode == "native" or mode == "separator" then
                if fixture.at_least(version, 3, 7) then
                    expected = "A^@^A^[^?M^?\nBENDMARK"
                end
                expected = expected:gsub("\n", mode == "separator" and "|" or "\r")
            end
            test.assertEquals(files.read(report), expected)
        end
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:out("list-clients"), "")
        test.assertEquals(f:try("has-session", "-t", "$0").code, 0)
    end)
end

local cases = {
    storage = "binary_storage_names_empty_refusal_and_output_limit",
    raw = "raw_paste_preserves_binary_and_line_feeds",
    native = "native_paste_preserves_release_sanitization",
    separator = "separator_replaces_line_feeds_without_enter",
    bracket = "bracketed_paste_uses_native_mode",
    disabled = "delete_after_paste_even_when_input_is_disabled",
}
for mode, name in pairs(cases) do
    fixture.each_host(M, name, function(host)
        run_case(mode, host)
    end)
end

return M
