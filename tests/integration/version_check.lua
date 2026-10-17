local mode = assert(os.getenv("LIBTMUX_VERSION_CHECK_CASE"))
if mode == "ranks" then
    -- The grammar has one home, fields.lua; the Python test asks it.
    local fields = require("libtmux._internal.fields")
    local ranked = {}
    for required in assert(os.getenv("LIBTMUX_RANK_REQUIRED")):gmatch("[^,]+") do
        local at_least = fields.at_least(assert(os.getenv("LIBTMUX_RANK_VERSION")), required)
        ranked[#ranked + 1] = at_least == nil and "none" or tostring(at_least)
    end
    print(table.concat(ranked, ","))
    return
end
local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local options = {
    binary = os.getenv("TMUX_CLIENT_BIN") or assert(os.getenv("TMUX_BIN")),
    socket_path = assert(os.getenv("TMUX_SOCKET")),
}

local function work(runtime)
    if mode == "fence_right" or mode == "fence_wrong" then
        -- Print the argv this library would run; the caller executes it.
        local command = require("libtmux._internal.command")
        local argv = assert(command.prepare({
            binary = options.binary,
            socket = options.socket_path,
            config = "/dev/null",
            no_start = true,
        }, { { "new-session", "-d", "-s", "fenced", "/bin/cat" } }, {
            version = mode == "fence_right" and assert(os.getenv("TMUX_DAEMON_VERSION")) or "9.9",
            marker = "libtmux-version-0123456789abcdef-",
        }))
        io.stdout:write(table.concat(argv, "\0"), "\0\n", mode, " passed\n")
        return mode .. " passed"
    end
    if mode:match("^control_fence_") then
        -- Attach through an endpoint whose evidence misstates the daemon; the
        -- real daemon must refuse the fence and attach nothing.
        local bound = assert(require("libtmux._internal.endpoint")
            .bind(runtime, {
                binary = options.binary,
                socket = options.socket_path,
                config = "/dev/null",
            })
            :await())
        local lie = mode:match("^control_fence_(.+)$")
        local view = setmetatable({}, {
            __index = function(_, key)
                return function(_, ...)
                    return bound[key](bound, ...)
                end
            end,
        })
        view.evidence = function()
            local evidence, evidence_error = bound:evidence()
            if evidence and lie == "wrong_pid" then
                evidence.pid = "1"
            elseif evidence and lie == "wrong_version" then
                evidence.version = "9.9"
            end
            return evidence, evidence_error
        end
        local connection, open_error = require("libtmux._internal.control")
            .open(runtime, view, { session_id = assert(os.getenv("TMUX_TEST_SESSION")) })
            :await()
        if lie == "right" then
            assert(connection, tostring(open_error))
            assert(connection:close():await())
        else
            assert(connection == nil, "a mismatched fence attached")
            assert(
                open_error.code == "stale_generation" and open_error.effect == "not_sent",
                tostring(open_error)
            )
        end
        assert(bound:close():await())
        return mode .. " passed"
    end
    local server, err = runtime:connect(options):await()
    if mode == "refuse" then
        assert(server == nil, "a daemon below the floor was accepted")
        assert(err.code == "unsupported_version" and err.effect == "not_sent", tostring(err))
        assert(err.message:find("restart the server", 1, true), "the refusal names no remedy")
        local phrase = assert(os.getenv("LIBTMUX_EXPECT_REFUSAL"))
        assert(err.message:find(phrase, 1, true), phrase .. " missing from: " .. err.message)
        return "refuse passed"
    end
    if mode == "snapshot" then
        assert(server, tostring(err))
        local snapshot =
            assert(server:snapshot({ fields = { sessions = { "id", "name" } } }):await())
        local found = false
        for _, session in ipairs(snapshot.sessions) do
            found = found or session.name == assert(os.getenv("LIBTMUX_EXPECT_NAME"))
        end
        assert(found, "snapshot lost the session name")
        assert(server:close():await())
        return "snapshot passed"
    end
    if mode == "observe" then
        assert(server, tostring(err))
        local snapshot =
            assert(server:snapshot({ fields = { sessions = { "id", "name" } } }):await())
        local session = assert(server:handle(snapshot, assert(snapshot.sessions:first())))
        local observer = assert(server:observe(session):await())
        assert(observer:close():await())
        assert(server:close():await())
        return "observe passed"
    end
    assert(mode == "supported", "unknown version check case")
    assert(server, tostring(err))
    local created
    created, err = server:command({ "new-session", "-d", "-s", "supported", "/bin/cat" }):await()
    assert(created, tostring(err))
    assert(server:close():await())
    return "supported passed"
end

if host then
    adapter.start(work, function(result, err)
        if not result then
            io.stderr:write(tostring(err) .. "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(result .. "\n")
            host.cmd("qa!")
        end
    end)
else
    local result, err = adapter.run(work)
    assert(result, tostring(err))
    print(result)
end
