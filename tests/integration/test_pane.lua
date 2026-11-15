-- Typed Pane operations against owned tmux servers with event barriers.
local test = require("luaunit")
local files = require("support.files")
local fixture = require("tests.support.fixture")
local repo = require("support.repo")
local M = {}

local TEXT = "literal;#{pane_id}\\λ雪"

local function run_case(case, host)
    fixture.with(function(f)
        local report = f.path .. "/pane.bin"
        local result = f:program(host, "pane", {
            LIBTMUX_PANE_CASE = case,
            LIBTMUX_PANE_SCRIPT = repo.root .. "/tests/support/programs/pane.lua",
            LIBTMUX_PANE_REPORT = report,
            LIBTMUX_PANE_CWD = f.path,
        })
        test.assertStrContains(result.stdout, "public Pane operations PASS")
        -- The typed text and the key in hex, or the respawn's directory and value.
        local expected = case == "io" and TEXT .. "\0" .. "0d" or f.path .. "\0literal#{pid};"
        test.assertEquals(files.read(report), expected)
        test.assertEquals(f:out("list-clients"), "")
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:try("has-session", "-t", "$0").code, 0)
    end)
end

fixture.each_host(M, "capture_text_keys_and_explicit_copy_mode", function(host)
    run_case("io", host)
end)
fixture.each_host(M, "resize_kill_and_respawn_preserve_target_identity", function(host)
    run_case("mutations", host)
end)

return M
