local t = require("luaunit")
local features = require("libtmux._internal.features")
local M = {}

local function refused(version, argv, required)
    local err = assert(features.command(version, argv), version .. " " .. table.concat(argv, " "))
    t.assertEquals(err.code, "unsupported")
    t.assertEquals(err.effect, "not_sent")
    t.assertEquals(err.version, version)
    if required then
        t.assertEquals(err.required, required)
    end
end

local function allowed(version, argv)
    t.assertNil(features.command(version, argv), version .. " " .. table.concat(argv, " "))
end

function M.test_control_acquisition_needs_the_daemon_to_be_3_7()
    for _, version in ipairs({ "3.3a", "3.4", "3.5a", "3.6b" }) do
        local err = assert(features.control(version), version)
        t.assertEquals(err.code, "unsupported")
        t.assertEquals(err.required, "3.7")
        t.assertEquals(err.version, version)
        t.assertStrContains(err.message, "requires tmux 3.7 or newer")
    end
    for _, version in ipairs({ "3.7", "3.7a", "3.7c", "3.8", "3.10", "4.0" }) do
        t.assertNil(features.control(version), version)
    end
    -- A development build counts as the release it names.
    t.assertNil(features.control("next-3.9"))
    t.assertNil(features.control("3.8-rc2"))
    t.assertNotNil(features.control("next-3.6"))
    t.assertNotNil(features.control("3.6-rc1"))
    -- A version this library cannot place never starts a control client.
    t.assertNotNil(features.control("master"))
    ---@diagnostic disable-next-line: param-type-mismatch
    t.assertNotNil(features.control(nil))
end

function M.test_break_pane_is_refused_only_on_exactly_3_7_by_name_alias_or_prefix()
    for _, word in ipairs({ "break-pane", "breakp", "break", "break-p" }) do
        refused("3.7", { word, "-t", "%1" }, "3.7a")
        refused("3.7", { word, "-n", "named" }, "3.7a")
    end
    for _, version in ipairs({ "3.3a", "3.4", "3.6b", "3.7a", "3.7c" }) do
        allowed(version, { "break-pane", "-t", "%1" })
    end
    allowed("3.7", { "break-window" })
    allowed("next-3.9", { "break-pane", "-t", "%1" })
    allowed("next-3.9", { "delete-buffer", "-b", "name" })
    refused("next-3.3a", { "delete-buffer", "-b", "name" }, "3.4")
    allowed("3.7", { "list-panes" })
end

function M.test_commands_nested_in_another_command_are_not_inspected()
    -- The guard reads only the first word of an item. A refused command inside
    -- the argument of another command reaches tmux unguarded.
    allowed("3.7", { "if-shell", "true", "break-pane" })
    allowed("3.7", { "run-shell", "-C", "break-pane" })
    allowed("3.4", { "if-shell", "-F", "1", "split-window -p 30" })
    allowed("3.3a", { "if-shell", "true", "delete-buffer -b missing" })
    refused("3.7", { "break-pane" })
end

function M.test_nested_break_pane_passes_the_guard_on_exactly_3_7_with_a_direct_control()
    -- tmux 3.7 stops its server on this nested form; 3.7a survives it. The
    -- limit is documented in docs/commands.md.
    allowed("3.7", { "if-shell", "-F", "1", "break-pane -d" })
    allowed("3.7a", { "if-shell", "-F", "1", "break-pane -d" })
    allowed("3.7", { "run-shell", "-C", "break-pane -d" })
    refused("3.7", { "break-pane", "-d" }, "3.7a")
    allowed("3.7a", { "break-pane", "-d" })
end

function M.test_split_window_percent_is_refused_only_on_3_4()
    refused("3.4", { "split-window", "-p", "30" })
    -- The daemon already is 3.4, so there is no release to ask for.
    t.assertNil(features.command("3.4", { "split-window", "-p", "30" }).required)
    refused("3.4", { "splitw", "-dp30" })
    refused("3.4", { "split", "-d", "-t", "%1", "-p", "50" })
    allowed("3.4", { "split-window", "-l", "30%" })
    allowed("3.4", { "split-window", "-l", "30%", "--", "-p" })
    allowed("3.4", { "split-window", "-c", "-p" })
    for _, version in ipairs({ "3.3a", "3.5", "3.7c" }) do
        allowed(version, { "split-window", "-p", "30" })
    end
end

function M.test_layouts_below_3_4_need_a_checksum_or_a_unique_preset()
    for _, version in ipairs({ "3.3a" }) do
        for _, layout in ipairs({
            "",
            "x",
            "abc",
            "12345",
            "123,",
            "ffff:80x24",
            "even",
            "main",
            "t-",
        }) do
            refused(version, { "select-layout", "-t", "@1", layout }, "3.4")
            refused(version, { "selectl", "--", layout })
        end
        for _, layout in ipairs({ "tiled", "til", "even-h", "main-v", "ffff,80x24,0,0,1" }) do
            allowed(version, { "select-layout", "-t", "@1", layout })
        end
        -- -o skips the preset lookup, so only a checksum header is safe.
        refused(version, { "select-layout", "-o", "tiled" })
        allowed(version, { "select-layout", "-o", "ffff,80x24,0,0,1" })
        allowed(version, { "select-layout", "-n" })
        allowed(version, { "select-layout", "-t", "@1" })
        allowed(version, { "next-layout", "-t", "@1" })
    end
    for _, version in ipairs({ "3.4", "3.7c" }) do
        allowed(version, { "select-layout", "garbage" })
    end
end

function M.test_named_buffer_deletion_and_rename_need_3_4()
    refused("3.3a", { "delete-buffer", "-b", "name" }, "3.4")
    refused("3.3a", { "deleteb", "-bname" }, "3.4")
    refused("3.3a", { "set-buffer", "-b", "old", "-n", "new" }, "3.4")
    refused("3.3a", { "setb", "-b", "old", "-nnew" }, "3.4")
    -- Without a name tmux deletes the top buffer, and a named write is exact.
    allowed("3.3a", { "delete-buffer" })
    allowed("3.3a", { "set-buffer", "-b", "name", "data" })
    allowed("3.3a", { "paste-buffer", "-d", "-b", "name" })
    allowed("3.3a", { "set-buffer", "--", "-n" })
    for _, version in ipairs({ "3.4", "3.5", "3.7c" }) do
        allowed(version, { "delete-buffer", "-b", "name" })
        allowed(version, { "set-buffer", "-b", "old", "-n", "new" })
    end
end

function M.test_clipboard_query_needs_3_6a()
    for _, argv in ipairs({
        { "refresh-client", "-l" },
        { "refresh", "-l" },
        { "refresh-c", "-t", "/dev/pts/1", "-l" },
        { "refresh-client", "-Sl" },
        { "refresh-client", "-l%1" },
    }) do
        for _, version in ipairs({ "3.3a", "3.4", "3.5", "3.5a", "3.6" }) do
            refused(version, argv, "3.6a")
        end
        for _, version in ipairs({ "3.6a", "3.6b", "3.7c", "3.8", "next-3.9" }) do
            allowed(version, argv)
        end
    end
    allowed("3.3a", { "refresh-client", "-S" })
    allowed("3.3a", { "refresh-client", "-t", "-l" })
end

function M.test_exact_3_7_names_reject_dots_and_colons_before_dispatch()
    refused("3.7", { "new-session", "-d", "-s", "a.b" }, "3.7a")
    refused("3.7", { "new", "-ds", "a:b" })
    refused("3.7", { "new-session", "-n", "w.1" })
    refused("3.7", { "new-window", "-n", "w:1" })
    refused("3.7", { "neww", "-dnw.1" })
    refused("3.7", { "rename-session", "-t", "$1", "a.b" })
    refused("3.7", { "rename-window", "-t", "@1", "--", "a:b" })
    refused("3.7", { "renamew", "x.y" })
    allowed("3.7", { "new-session", "-d", "-s", "plain", "-n", "window" })
    allowed("3.7", { "new-window", "-t", "=s:1", "-n", "plain" })
    allowed("3.7", { "rename-window", "-t", "@1.0", "plain" })
    allowed("3.7", { "new-session", "-d", "-c", "/tmp/a.b", "-e", "A=b.c" })
    allowed("3.7", { "new-window", "-c", "/tmp/a:b" })
    for _, version in ipairs({ "3.3a", "3.6b", "3.7a", "3.7c" }) do
        allowed(version, { "new-session", "-d", "-s", "a.b" })
        allowed(version, { "rename-window", "x.y" })
    end
end

function M.test_candidates_and_development_builds_rank_below_the_release_they_name()
    -- Control acquisition needs a build at or above 3.7 final.
    for _, version in ipairs({ "next-3.7", "3.7-rc", "3.7-rc2" }) do
        t.assertNotNil(features.control(version), version)
        -- The exact-3.7 guards describe the 3.7 release itself.
        allowed(version, { "break-pane", "-t", "%1" })
        allowed(version, { "new-session", "-d", "-s", "a.b" })
    end
    for _, version in ipairs({ "3.7a", "3.8-rc2", "next-3.8" }) do
        t.assertNil(features.control(version), version)
    end
    refused("next-3.4", { "delete-buffer", "-b", "name" }, "3.4")
    refused("3.4-rc", { "set-buffer", "-b", "old", "-n", "new" }, "3.4")
    allowed("3.4", { "delete-buffer", "-b", "name" })
    allowed("next-3.5", { "delete-buffer", "-b", "name" })
end

function M.test_commands_scans_every_item_and_ignores_non_matching_words()
    local commands = { { "list-sessions" }, { "display-message", "-p", "break-pane" }, { "ls" } }
    t.assertNil(features.commands("3.7", commands))
    commands[#commands + 1] = { "breakp" }
    t.assertNotNil(features.commands("3.7", commands))
    -- Ambiguous words are tmux's error, not a guarded command.
    t.assertNil(features.command("3.7", { "s" }))
    t.assertNil(features.command("3.7", { "new-" }))
    t.assertNil(features.command("3.7", { "" }))
end

return M
