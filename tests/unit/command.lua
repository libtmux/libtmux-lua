local t = require("luaunit")
local available, command = pcall(require, "libtmux._internal.command")
local M = {}
local endpoint = { binary = "tmux-test", socket = "/owned/socket;", config = "/owned/config;" }

function M.test_prepare_preserves_arguments_through_tmux_separator_parser()
    t.assertTrue(available, "command layer is not implemented")
    local argv = {
        "set-buffer",
        "",
        "quote'\"",
        "slash\\",
        "line\nreturn\r",
        "$HOME~#{pane_id}",
        "\255",
        ";",
        "tail;",
        "tail\\;",
        "tail;;",
    }
    local encoded, err = command.prepare(endpoint, { argv })
    t.assertNil(err)
    t.assertEquals(encoded, {
        "tmux-test",
        "-S",
        "/owned/socket;",
        "-f",
        "/owned/config;",
        "--",
        "set-buffer",
        "",
        "quote'\"",
        "slash\\",
        "line\nreturn\r",
        "$HOME~#{pane_id}",
        "\255",
        "\\;",
        "tail\\;",
        "tail\\\\;",
        "tail;\\;",
    })
    t.assertEquals(argv[10], "tail\\;")
end

function M.test_only_explicit_group_boundaries_become_separator_tokens()
    t.assertTrue(available, "command layer is not implemented")
    local encoded = command.prepare({ socket = "/owned/socket" }, {
        { "set-option", "-g", "@literal", ";" },
        { "display-message", "-p", "second;" },
    })
    t.assertEquals(encoded, {
        "tmux",
        "-S",
        "/owned/socket",
        "--",
        "set-option",
        "-g",
        "@literal",
        "\\;",
        ";",
        "display-message",
        "-p",
        "second\\;",
    })
end

function M.test_bound_endpoint_can_disable_tmux_server_autostart()
    local encoded, err = command.prepare({ socket = "/owned/pin", no_start = true }, {
        { "new-session", "-d" },
    })
    t.assertNil(err)
    t.assertEquals(encoded, { "tmux", "-S", "/owned/pin", "-N", "--", "new-session", "-d" })
    local invalid, invalid_err = command.prepare({ socket = "/owned/pin", no_start = "yes" }, {
        { "new-session" },
    })
    t.assertNil(invalid)
    assert(invalid_err)
    t.assertEquals(invalid_err.code, "invalid_endpoint")
end

function M.test_invalid_group_member_rejects_whole_submission_without_effects()
    t.assertTrue(available, "command layer is not implemented")
    for _, commands in ipairs({
        {},
        { {} },
        { { "valid" }, { "nul\000" } },
        { { "valid" }, { "bad", false } },
        { [2] = { "sparse" } },
        { { "" } },
    }) do
        local encoded, err = command.prepare(endpoint, commands)
        t.assertNil(encoded)
        assert(err)
        t.assertEquals(err.code, "invalid_command")
        t.assertEquals(err.effect, "not_sent")
    end
    for _, invalid in ipairs({
        false,
        {},
        { socket = "nul\000" },
        { socket = "valid", extra = true },
    }) do
        local encoded, err = command.prepare(invalid, { { "valid" } })
        t.assertNil(encoded)
        assert(err)
        t.assertEquals(err.code, "invalid_endpoint")
        t.assertEquals(err.effect, "not_sent")
    end
end

function M.test_metatables_are_rejected_without_running_code()
    t.assertTrue(available, "command layer is not implemented")
    local touched = false
    local function touch()
        touched = true
        error("input metamethod must not run")
    end
    local mt = { __len = touch, __pairs = touch, __index = touch }
    local cases = { setmetatable({ { "valid" } }, mt), { setmetatable({ "valid" }, mt) } }
    for _, value in ipairs(cases) do
        local encoded, err = command.prepare(endpoint, value)
        t.assertNil(encoded)
        assert(err)
        t.assertEquals(err.effect, "not_sent")
        t.assertFalse(touched)
    end
    local encoded, err =
        command.prepare(setmetatable({ socket = "/owned/socket" }, mt), { { "valid" } })
    t.assertNil(encoded)
    assert(err)
    t.assertEquals(err.code, "invalid_endpoint")
    t.assertFalse(touched)
end

return M
