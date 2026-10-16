local adapter = require("libtmux.runtime.luv")
local codec = require("libtmux._internal.codec")
local errors = require("libtmux._internal.error")
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
    for _, mode in ipairs({ "success", "cancel", "rollback" }) do
        if not os.getenv("HANDOFF_MODE") or os.getenv("HANDOFF_MODE") == mode then
            local published, other = root .. "/handoff-" .. mode, root .. "/other-" .. mode
            local replacement = must(runtime:owned_server({ socket_path = other }):await())
            local replacement_pid = replacement:receipt().pid
            local link, decode = uv.fs_link, codec.decode
            local installed, injected, private, pending, accepted_pid
            ---@diagnostic disable-next-line: duplicate-set-field
            uv.fs_link = function(from, to, callback)
                local ok, err = link(from, to, callback)
                if ok and to == published then
                    assert(not callback)
                    private = from
                    must(uv.fs_unlink(published))
                    must(link(other, published))
                    installed = true
                end
                return ok, err
            end
            ---@diagnostic disable-next-line: duplicate-set-field
            codec.decode = function(text, count, options)
                local rows, err = decode(text, count, options)
                if installed and count == 7 and rows and rows[1] and not injected then
                    injected, accepted_pid = true, rows[1][1]
                    if mode == "cancel" then
                        pending:cancel("cancel during startup acceptance")
                    end
                    if mode == "rollback" then
                        return nil, errors.new("injected_receipt", "fail startup receipt parsing")
                    end
                end
                return rows, err
            end
            pending = runtime:find_or_create_server({ socket_path = published })
            local found, startup_error = pending:await()
            uv.fs_link, codec.decode = link, decode
            local public = runtime:connect({ socket_path = published }):await()
            local response = public
                and public:command({ "display-message", "-p", "#{pid}" }):await()
            local reachable = response and response.stdout == replacement_pid .. "\n"
            print(
                mode
                    .. ": accepted PID "
                    .. tostring(accepted_pid)
                    .. ", replacement PID "
                    .. replacement_pid
            )
            print(mode .. ": replacement public endpoint reachable " .. tostring(reachable == true))
            assert(installed and injected)
            assert(reachable, "startup cleanup destroyed the replacement daemon")
            assert(public)
            assert(accepted_pid ~= replacement_pid, "startup accepted the replacement daemon")
            if mode == "success" then
                assert(found and found.created and found.owner, tostring(startup_error))
                assert(found.owner.value == found.value)
                assert(found.owner:receipt().pid == accepted_pid)
                local owned =
                    must(found.value:command({ "display-message", "-p", "#{pid}" }):await())
                assert(
                    owned.stdout == accepted_pid .. "\n",
                    "returned handle must retain the created daemon"
                )
                must(found.owner:close():await())
            elseif mode == "cancel" then
                assert(not found and startup_error and startup_error.code == "cancelled")
            else
                assert(not found and startup_error)
            end
            assert(uv.fs_lstat(private) == nil)
            assert(uv.fs_lstat(private:match("^(.*)/s$")) == nil)
            local again = must(public:command({ "display-message", "-p", "#{pid}" }):await())
            assert(again.stdout == replacement_pid .. "\n", "close must retain replacement")
            must(replacement:close():await())
        end
    end
    print("private startup handoff success/cancellation/rollback PASS")
    return true
end)
assert(result, tostring(failure))
