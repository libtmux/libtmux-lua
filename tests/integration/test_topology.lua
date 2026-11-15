-- Stable entity mutations and native topology side effects on owned servers.
local test = require("luaunit")
local files = require("support.files")
local fixture = require("tests.support.fixture")
local repo = require("support.repo")
local M = {}

local RESPAWN = repo.root .. "/tests/support/programs/respawn.lua"

local function run_case(mode, host, automatic)
    fixture.with({ env = { LC_ALL = "C", LANG = "C" } }, function(f)
        local extra = {
            LIBTMUX_TOPOLOGY_CASE = mode,
            TMUX_DAEMON_VERSION = f:version(),
            LIBTMUX_BREAK_AUTOMATIC = automatic and "1" or "0",
        }
        local report = f.path .. "/respawn.bin"
        if mode == "window_respawn" then
            extra.LIBTMUX_RESPAWN_SCRIPT = RESPAWN
            extra.LIBTMUX_RESPAWN_REPORT = report
            extra.LIBTMUX_TEST_DIRECTORY = f.path
        end
        local result = f:program(host, "topology", extra)
        test.assertStrContains(result.stdout, ("public topology %s PASS"):format(mode))
        if mode == "window_respawn" then
            -- SCOPE, VALUE and the three arguments, as bytes.
            test.assertEquals(
                files.read(report),
                "target\0literal#{pid};\0literal;$#{}\\\"\0\0~$HOME'\n #literal\r\tλ"
            )
        end
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:out("list-clients"), "")
        test.assertEquals(f:try("has-session", "-t", "$0").code, 0)
    end)
end

local cases = {
    pane_selection_title_and_zoom = "pane_selection",
    pane_swap_identity_selection_and_missing_target = "pane_swap",
    session_window_rename_and_kill_scope = "rename_kill",
    session_navigation_and_renumber = "navigation",
    window_dimensions_layout_and_error_side_effect = "layout",
    link_identity_selection_noop_unlink_and_index_reuse = "link_identity",
    link_insertion_move_replacement_and_stale_destination = "link_placement",
    link_swap_selection_and_stale_handles = "link_swap",
    link_group_propagation_and_cross_group_refusal = "link_group",
    link_cross_session_move_swap_and_free_index = "link_cross_session",
    window_respawn_launch_context_and_pane_identity = "window_respawn",
    window_respawn_refuses_invalid_and_replaced_context = "window_respawn_stale",
    pane_move_preserves_identity_geometry_and_destroys_empty_window = "pane_move",
    pane_move_selection_context_and_stale_membership = "pane_move_context",
    pane_break_occupied_destination_and_stale_membership = "break_refusal",
}
for name, mode in pairs(cases) do
    fixture.each_host(M, name, function(host)
        run_case(mode, host)
    end)
end

-- A break runs once with the library's naming and once with tmux's automatic naming.
local breaks = {
    pane_break_singleton_named = "break_single_named",
    pane_break_singleton_default_name = "break_single_default",
    pane_break_multiple_named = "break_multi_named",
    pane_break_multiple_default_name = "break_multi_default",
}
for name, mode in pairs(breaks) do
    for _, automatic in ipairs({ false, true }) do
        fixture.each_host(M, name .. (automatic and "_automatic" or "_manual"), function(host)
            run_case(mode, host, automatic)
        end)
    end
end

return M
