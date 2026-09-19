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
        "-u",
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
        "-u",
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
    t.assertEquals(encoded, { "tmux", "-S", "/owned/pin", "-u", "-N", "--", "new-session", "-d" })
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

local function program(input)
    t.assertEquals(type(command.prepare_program), "function", "hook program preparation is missing")
    return command.prepare_program(input)
end

local function invalid_program(input)
    local value, err = program(input)
    t.assertNil(value)
    assert(err)
    t.assertEquals(err.code, "invalid_program")
    t.assertEquals(err.effect, "not_sent")
end

function M.test_program_commands_quote_each_byte_and_only_explicit_command_boundaries()
    local input = { commands = { { "a", "", "\n;\255" }, { "b", "%end\\$" } } }
    local encoded, err = program(input)
    t.assertNil(err)
    t.assertEquals(
        encoded,
        '"\\141" "" "\\012\\073\\377" ; "\\142" "\\045\\145\\156\\144\\134\\044"'
    )
    t.assertEquals(input.commands[1], { "a", "", "\n;\255" })
    input.commands[1][1] = "changed"
    t.assertStrContains(encoded, '"\\141"')
    local source = "not-yet-a-command\n%end 1 2 1\r\t\\\255"
    t.assertEquals(program({ source = source }), source)
    t.assertEquals(program({ source = "" }), "")
end

function M.test_program_validation_rejects_ambiguous_records_and_untrusted_tables()
    local touched = false
    local function touch()
        touched = true
        error("program validation must not run caller code")
    end
    local mt = { __index = touch, __pairs = touch, __len = touch, __tostring = touch }
    for _, input in ipairs({
        false,
        {},
        { commands = { { "a" } }, source = "a" },
        { source = "a", extra = true },
        { source = "a\000b" },
        { source = false },
        { commands = false },
        { commands = {} },
        { commands = { {} } },
        { commands = { { "" } } },
        { commands = { { "a" }, { "b", "\000" } } },
        { commands = { { "a" }, { "b", false } } },
        { commands = { [2] = { "a" } } },
        { commands = { { [1] = "a", [3] = "hole" } } },
        setmetatable({ source = "a" }, mt),
        { commands = setmetatable({ { "a" } }, mt) },
        { commands = { setmetatable({ "a" }, mt) } },
        { commands = { { "a", setmetatable({}, mt) } } },
    }) do
        invalid_program(input)
    end
    t.assertFalse(touched)
end

function M.test_program_limits_cover_encoded_expansion_commands_and_aggregate_arguments()
    local maximum = 1048576
    t.assertEquals(#assert(program({ source = string.rep("x", maximum) })), maximum)
    invalid_program({ source = string.rep("x", maximum + 1) })
    local commands = { { "a", string.rep("x", (maximum - 8) / 4 - 1), "" } }
    t.assertEquals(#assert(program({ commands = commands })), maximum)
    commands[1][2] = commands[1][2] .. "x"
    invalid_program({ commands = commands })
    commands = {}
    for index = 1, 1024 do
        commands[index] = { "a", "", "", "" }
    end
    t.assertNotNil(program({ commands = commands }))
    commands[1][5] = ""
    invalid_program({ commands = commands })
    commands[1][5], commands[1025] = nil, { "a" }
    invalid_program({ commands = commands })
end

return M
