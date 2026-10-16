local adapter = require("libtmux.runtime.luv")
local defaults = require("libtmux._internal.defaults")
-- luv is the native host module, distinct from libtmux.runtime.luv.
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end
local result, failure = adapter.run(function(runtime)
    local root = assert(os.getenv("LIBTMUX_TEST_ROOT"))
    local binary = assert(os.getenv("LIBTMUX_TEST_BINARY"))
    local cases = {
        { root .. "/first", root .. "/second", root .. "/first" },
        { "", root .. "/second", "/tmp" },
        { root .. "/first", "", root .. "/first" },
    }
    for _, case in ipairs(cases) do
        for _, path_selector in ipairs({ false, true }) do
            local env = { "TMUX_TMPDIR=" .. case[1], "TMUX_TMPDIR=" .. case[2] }
            if path_selector then
                env[#env + 1] = "LIBTMUX_SOCKET_PATH=" .. root .. "/socket"
            end
            local options = { binary = binary, env = env }
            local selected = must(defaults.resolve(uv, {
                binary = binary,
                socket_name = "default",
                env = env,
            }))
            local expected = case[3] .. "/tmux-" .. uv.getuid()
            assert(selected.socket == expected .. "/default")
            local inspected, lstat = {}, uv.fs_lstat
            ---@diagnostic disable-next-line: duplicate-set-field
            uv.fs_lstat = function(path, callback)
                assert(not callback, "only synchronous root admission is expected")
                inspected[#inspected + 1] = path
                return nil, "ENOENT: test blocks root enumeration"
            end
            local discovery, err = runtime:discover_servers(options):await()
            uv.fs_lstat = lstat
            must(discovery, err)
            assert(inspected[1] == expected, "discovery must share connection/getenv precedence")
            assert(#inspected == (case[3] == "/tmp" and 1 or 2))
            print("first entry [" .. case[1] .. "] selects " .. expected)
        end
    end
    print("discovery first/empty duplicate environment entries PASS 6 cases")
    return true
end)
assert(result, tostring(failure))
