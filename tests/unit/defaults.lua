local t = require("luaunit")
local defaults = require("libtmux._internal.defaults")
local M = {}

local function host(env)
    return {
        os_environ = function()
            return env or {}
        end,
        getuid = function()
            return 1000
        end,
        cwd = function()
            return "/cwd"
        end,
        fs_stat = function(path)
            if path == "/usr/bin/tmux" or path == "/cwd/bin/tmux" then
                return { type = "file" }
            end
        end,
        fs_access = function()
            return true
        end,
    }
end

local function resolve(env, options)
    return assert(defaults.resolve(host(env), options))
end

function M.test_default_selection_is_pure_and_does_not_connect_to_ambient_server()
    local value = resolve({})
    t.assertEquals(value.socket, "/tmp/tmux-1000/default")
    t.assertEquals(value.binary, "/usr/bin/tmux")
    t.assertEquals(value.config, "/dev/null")
    t.assertEquals(value.env, {})
end

function M.test_precedence_ignores_weaker_invalid_values()
    local env = {
        LIBTMUX_SOCKET_PATH = "/chosen",
        LIBTMUX_SOCKET_NAME = "../bad",
        TMUX = "invalid",
        TMUX_TMPDIR = "relative",
    }
    t.assertEquals(resolve(env).socket, "/chosen")
    t.assertEquals(resolve(env, { socket_path = "/explicit" }).socket, "/explicit")
    env.TMUX_TMPDIR = "/root"
    t.assertEquals(resolve(env, { socket_name = "explicit" }).socket, "/root/tmux-1000/explicit")
    env.LIBTMUX_SOCKET_PATH = ""
    env.LIBTMUX_SOCKET_NAME = "selected"
    t.assertEquals(resolve(env).socket, "/root/tmux-1000/selected")
    env.LIBTMUX_SOCKET_NAME = ""
    env.TMUX = "/path,with,commas,123,$4"
    t.assertEquals(resolve(env).socket, "/path,with,commas")
    env.TMUX = ""
    t.assertEquals(resolve(env).socket, "/root/tmux-1000/default")
end

function M.test_selected_values_fail_without_fallback()
    for _, options in ipairs({
        { socket_name = "" },
        { socket_name = "." },
        { socket_name = ".." },
        { socket_name = "a/b" },
        { socket_name = "a\\b" },
        { socket_name = "a\000b" },
        { socket_path = "relative" },
        { socket_path = "" },
        { socket_path = "/bad/" },
        { socket_path = "/ok", socket_name = "name" },
        { binary = "tmux" },
        { config_path = "relative" },
        { unknown = true },
    }) do
        local value, err = defaults.resolve(host(), options)
        t.assertNil(value)
        assert(err)
        t.assertEquals(err.code, "invalid_endpoint")
        t.assertEquals(err.effect, "not_sent")
    end
    for _, env in ipairs({
        { LIBTMUX_SOCKET_PATH = "relative", LIBTMUX_SOCKET_NAME = "valid" },
        { LIBTMUX_SOCKET_NAME = "../invalid", TMUX = "/path,1,0" },
        { TMUX_TMPDIR = "relative" },
    }) do
        local value, err = defaults.resolve(host(env))
        t.assertNil(value)
        assert(err)
        t.assertEquals(err.code, "invalid_endpoint")
    end
end

function M.test_tmux_context_parses_last_two_commas_and_preserves_path_bytes()
    for _, session in ipairs({ "0", "$0", "0002", "$42", "-1" }) do
        local path = "/tmp/ a,b "
        local value = resolve({ TMUX = path .. ",0001," .. session, TMUX_PANE = "%9" })
        t.assertEquals(value.socket, path)
        t.assertEquals(
            value.context,
            { socket = path, pid = "0001", session = session, pane = "%9" }
        )
        t.assertEquals(value.env, {})
    end
end

function M.test_malformed_tmux_context_is_an_error()
    for _, value in ipairs({
        "invalid",
        "/tmp/one,1",
        ",1,0",
        "relative,1,0",
        "/path,0,0",
        "/path,000,0",
        "/path,-1,0",
        "/path,+1,0",
        "/path,1 ,0",
        "/path,,0",
        "/path,1,",
        "/path,1,-2",
        "/path,1,+1",
        "/path,1, 1",
        "/path,1,$-1",
        "/path,1,$$1",
        "/path,1,1x",
        "/path,1,0,extra",
        "/path\000,1,0",
    }) do
        local resolved, err = defaults.resolve(host({ TMUX = value }))
        t.assertNil(resolved, value)
        assert(err)
        t.assertEquals(err.code, "invalid_endpoint", value)
    end
end

function M.test_names_and_roots_preserve_filesystem_components()
    for _, root in ipairs({ "/root/missing/../selected", "/root/symlink/..", "/root/space " }) do
        t.assertEquals(
            resolve({ TMUX_TMPDIR = root }, { socket_name = " a,b " }).socket,
            root .. "/tmux-1000/ a,b "
        )
    end
end

function M.test_environment_and_overrides_are_copied_without_host_mutation()
    local env = {
        KEEP = "before",
        DELETE = "yes",
        TMUX = "invalid",
        TMUX_PANE = "%1",
        LIBTMUX_SOCKET_PATH = "/from-host",
    }
    local options = {
        client_env = {
            KEEP = "override",
            DELETE = false,
            LIBTMUX_SOCKET_PATH = "/from-child",
        },
    }
    local value = resolve(env, options)
    env.KEEP = "after"
    options.client_env.KEEP = "after"
    t.assertEquals(value.socket, "/from-child")
    t.assertEquals(value.env, { "KEEP=override", "LIBTMUX_SOCKET_PATH=/from-child" })
    t.assertEquals(env.DELETE, "yes")
    t.assertEquals(env.TMUX, "invalid")
    t.assertEquals(env.TMUX_PANE, "%1")
end

function M.test_captured_executable_search_and_validation()
    t.assertEquals(resolve({ PATH = "missing:bin:/usr/bin" }).binary, "/cwd/bin/tmux")
    local value, err = defaults.resolve(host({ PATH = "/missing" }))
    t.assertNil(value)
    assert(err)
    t.assertEquals(err.code, "invalid_endpoint")
    for _, overrides in ipairs({ { ["a=b"] = "x" }, { A = 1 }, { A = "x\000" }, false }) do
        value, err = defaults.resolve(host(), { client_env = overrides })
        t.assertNil(value)
        assert(err)
        t.assertEquals(err.code, "invalid_endpoint")
    end
end

function M.test_connection_full_environment_sequence_and_empty_environment()
    local ambient = { LEAK = "ambient", LIBTMUX_SOCKET_PATH = "/wrong", PATH = "/missing" }
    local options = { binary = "/usr/bin/tmux", socket_path = "/selected", env = {} }
    local value = resolve(ambient, options)
    t.assertEquals(value.env, {})
    t.assertEquals(value.socket, "/selected")
    options.env = {
        "KEY=first",
        "KEY=second",
        "PATH=/usr/bin",
        "LIBTMUX_SOCKET_PATH=/sequence",
        "TMUX=/ignored,1,0",
        "TMUX_PANE=%1",
        "",
        "bare-entry",
    }
    options.socket_path = nil
    value = resolve(ambient, options)
    options.env[1] = "KEY=changed"
    t.assertEquals(value.socket, "/sequence")
    t.assertEquals(value.env, {
        "KEY=first",
        "KEY=second",
        "PATH=/usr/bin",
        "LIBTMUX_SOCKET_PATH=/sequence",
        "",
        "bare-entry",
    })
    t.assertEquals(ambient.LEAK, "ambient")
end

function M.test_full_environment_and_override_map_are_mutually_exclusive()
    for _, options in ipairs({
        { env = {}, client_env = {} },
        { env = { [2] = "PATH=/usr/bin" } },
        { env = { "BAD=\000" } },
        { env = false },
    }) do
        local value, err = defaults.resolve(host(), options)
        t.assertNil(value)
        t.assertEquals(assert(err).code, "invalid_endpoint")
    end
end

function M.test_discovery_and_connection_share_first_tmpdir_value()
    for _, case in ipairs({
        { "/first", "/second", "/first" },
        { "", "/second", "/tmp" },
        { "/first", "", "/first" },
    }) do
        local entries = { "TMUX_TMPDIR=" .. case[1], "TMUX_TMPDIR=" .. case[2] }
        local endpoint = resolve({}, { binary = "/usr/bin/tmux", env = entries })
        t.assertEquals(defaults.socket_root(endpoint.env), case[3])
        t.assertEquals(endpoint.socket, case[3] .. "/tmux-1000/default")
        t.assertEquals(endpoint.env, entries)
    end
end

return M
