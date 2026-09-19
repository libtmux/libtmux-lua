local test = require("luaunit")
local tests = {}

local function catalog()
    local ok, module = pcall(require, "libtmux._internal.options_catalog")
    test.assertTrue(ok, "generated option catalog is missing")
    return module
end

function tests.test_exact_release_maps_refuse_unknown_versions_and_abbreviations()
    local options = catalog()
    local counts = {
        ["3.2a"] = 165,
        ["3.3"] = 181,
        ["3.3a"] = 181,
        ["3.4"] = 186,
        ["3.5"] = 190,
        ["3.5a"] = 190,
        ["3.6"] = 210,
        ["3.6a"] = 210,
        ["3.6b"] = 210,
        ["3.7"] = 221,
        ["3.7a"] = 221,
        ["3.7b"] = 221,
        ["3.7c"] = 221,
    }
    for version, count in pairs(counts) do
        local names = assert(options.names(version))
        test.assertEquals(#names, count)
        for index = 2, #names do
            test.assertTrue(names[index - 1] < names[index])
        end
        for _, name in ipairs(names) do
            test.assertEquals(assert(options.lookup(version, name)).name, name)
        end
    end
    ---@type any[]
    local invalid_versions = {
        "3.2",
        "3.2b",
        "3.7d",
        "3.8",
        "next-3.8",
        "3.7-rc",
        "tmux 3.7c",
        false,
    }
    for _, version in ipairs(invalid_versions) do
        local value, err = options.lookup(version, "history-limit")
        test.assertNil(value)
        test.assertEquals(assert(err).code, "unsupported_version")
        value, err = options.names(version)
        test.assertNil(value)
        test.assertEquals(assert(err).code, "unsupported_version")
    end
    ---@diagnostic disable-next-line: param-type-mismatch
    local value, err = options.lookup(nil, "history-limit")
    test.assertNil(value)
    test.assertEquals(assert(err).code, "unsupported_version")
    for _, name in ipairs({ "history-l", "pane-colors", "@custom", "pane-colours[0]" }) do
        value, err = options.lookup("3.7c", name)
        test.assertNil(value)
        test.assertEquals(assert(err).code, "unknown_option")
    end
    ---@diagnostic disable-next-line: param-type-mismatch
    value, err = options.names("3.7c", "command")
    test.assertNil(value)
    test.assertEquals(assert(err).code, "invalid_family")
end

function tests.test_scope_migrations_preserve_exact_native_storage()
    local options = catalog()
    test.assertEquals(assert(options.lookup("3.2a", "window-linked")).scopes, { "window" })
    test.assertEquals(assert(options.lookup("3.3", "window-linked")).scopes, { "session" })
    test.assertEquals(assert(options.lookup("3.2a", "window-unlinked")).scope_bits, 4)
    test.assertEquals(assert(options.lookup("3.3a", "window-unlinked")).scope_bits, 2)
    test.assertEquals(assert(options.lookup("3.2a", "pane-border-format")).scope_bits, 4)
    test.assertEquals(assert(options.lookup("3.3", "pane-border-format")).scope_bits, 12)
    test.assertEquals(assert(options.lookup("3.6b", "pane-border-style")).scopes, { "window" })
    test.assertEquals(
        assert(options.lookup("3.7", "pane-border-style")).scopes,
        { "window", "pane" }
    )
    test.assertEquals(assert(options.lookup("3.7c", "buffer-limit")).scopes, { "server" })
end

function tests.test_types_choices_and_bounds_are_selected_per_release()
    local options = catalog()
    test.assertEquals(assert(options.lookup("3.3a", "allow-passthrough")).native_type, "flag")
    test.assertNil(assert(options.lookup("3.3a", "allow-passthrough")).choices)
    test.assertEquals(assert(options.lookup("3.4", "allow-passthrough")).native_type, "choice")
    test.assertEquals(
        assert(options.lookup("3.4", "allow-passthrough")).choices,
        { "off", "on", "all" }
    )
    test.assertEquals(assert(options.lookup("3.3", "destroy-unattached")).native_type, "flag")
    test.assertEquals(
        assert(options.lookup("3.4", "destroy-unattached")).choices,
        { "off", "on", "keep-last", "keep-group" }
    )
    test.assertEquals(assert(options.lookup("3.5a", "repeat-time")).maximum, 32767)
    test.assertEquals(assert(options.lookup("3.6", "repeat-time")).maximum, 2000000)
    test.assertEquals(assert(options.lookup("3.7c", "input-buffer-size")).minimum, 1048576)
    test.assertEquals(assert(options.lookup("3.7c", "input-buffer-size")).maximum, 4294967295)
    test.assertEquals(assert(options.lookup("3.2a", "clock-mode-style")).choices, { "12", "24" })
    test.assertEquals(
        assert(options.lookup("3.6", "clock-mode-style")).choices,
        { "12", "24", "12-with-seconds", "24-with-seconds" }
    )
    local value, err = options.lookup("3.2a", "pane-colours")
    test.assertNil(value)
    test.assertEquals(assert(err).code, "unknown_option")
end

function tests.test_array_element_types_and_hook_family_do_not_conflate_commands()
    local options = catalog()
    local palette = assert(options.lookup("3.7c", "pane-colours"))
    test.assertEquals(palette.native_type, "colour")
    test.assertTrue(palette.array)
    test.assertFalse(palette.hook)
    test.assertNil(palette.separator)
    test.assertEquals(palette.array_separator, " ,")
    local aliases = assert(options.lookup("3.7c", "command-alias"))
    test.assertEquals(aliases.native_type, "string")
    test.assertEquals(aliases.array_separator, ",")
    local hook = assert(options.lookup("3.7c", "pane-exited"))
    test.assertEquals(hook.native_type, "command")
    test.assertTrue(hook.array)
    test.assertTrue(hook.hook)
    test.assertEquals(hook.array_separator, "")
    local command = assert(options.lookup("3.7c", "default-client-command"))
    test.assertEquals(command.native_type, "command")
    test.assertFalse(command.hook)
    test.assertFalse(command.array)
    local names = assert(options.names("3.7c", "option"))
    test.assertEquals(#names, 153)
    local seen = {}
    for _, name in ipairs(names) do
        seen[name] = true
        test.assertFalse(assert(options.lookup("3.7c", name)).hook)
    end
    test.assertTrue(seen["default-client-command"])
    test.assertTrue(seen["pane-colours"])
    local hooks = assert(options.names("3.7c", "hook"))
    test.assertEquals(#hooks, 68)
    for _, name in ipairs(hooks) do
        test.assertTrue(assert(options.lookup("3.7c", name)).hook)
    end
end

function tests.test_returned_metadata_and_names_cannot_corrupt_later_validation()
    local options = catalog()
    local choice = assert(options.lookup("3.7c", "allow-passthrough"))
    local choices = assert(choice.choices)
    choices[1] = "changed"
    choice.scopes[1] = "server"
    choice.native_type = "string"
    local fresh = assert(options.lookup("3.7c", "allow-passthrough"))
    test.assertEquals(fresh.choices, { "off", "on", "all" })
    test.assertEquals(fresh.scopes, { "window", "pane" })
    test.assertEquals(fresh.native_type, "choice")
    local names = assert(options.names("3.7c", "hook"))
    names[1] = "changed"
    test.assertEquals(assert(options.names("3.7c", "hook"))[1], "after-bind-key")
end

return tests
