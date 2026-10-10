local adapter = require("libtmux.runtime.luv")
-- luv is the native host module, distinct from libtmux.runtime.luv.
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
local servers = require("libtmux._internal.server")
local errors = require("libtmux._internal.error")

local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end

local function scenario(runtime, root, label, rollback)
    local published, other = root .. "/" .. label, root .. "/" .. label .. "-other"
    local replacement = must(runtime:owned_server({ socket_path = other }):await())
    local replacement_stat = must(uv.fs_lstat(other))
    local spawn, lstat, unlink, link, resolved =
        uv.spawn, uv.fs_lstat, uv.fs_unlink, uv.fs_link, servers.resolved
    local private, original_pid, original_stat, retired, injected, boundary
    local public_unlinks, bind_failures = 0, 0
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.spawn = function(binary, options, callback)
        local foreground = false
        for index, arg in ipairs(options.args) do
            if arg == "-D" then
                foreground = true
            end
            if foreground and arg == "-S" then
                private = options.args[index + 1]
            end
        end
        if foreground then
            local child, pid = spawn(binary, options, function(code, signal)
                retired = true
                callback(code, signal)
            end)
            original_pid = pid
            return child, pid
        end
        return spawn(binary, options, callback)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.fs_link = function(from, to, callback)
        local ok, err = link(from, to, callback)
        if ok and to == published then
            original_stat = must(lstat(to))
        end
        return ok, err
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.fs_lstat = function(path, callback)
        local stat, err = lstat(path, callback)
        if retired and not callback and not injected and (path == published or path == private) then
            assert(not callback and original_stat)
            -- Return the observed inode after a concurrent publisher replaces it.
            -- If cleanup no longer inspects the public alias, interleave at its
            -- private-path check instead and require zero public unlink attempts.
            must(unlink(published))
            must(link(other, published))
            local installed = must(lstat(published))
            assert(installed.ino == replacement_stat.ino and installed.dev == replacement_stat.dev)
            injected, boundary =
                true, path == published and "public lstat/unlink" or "private cleanup"
        end
        return stat, err
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    uv.fs_unlink = function(path, callback)
        if path == published then
            public_unlinks = public_unlinks + 1
        end
        return unlink(path, callback)
    end
    if rollback then
        ---@diagnostic disable-next-line: duplicate-set-field
        servers.resolved = function(rt, endpoint)
            if endpoint.socket == published or endpoint.socket == private then
                bind_failures = bind_failures + 1
                assert(original_stat, "failure must follow publication")
                return rt:_operation(function()
                    return nil, errors.new("injected_bind", "fail after publication")
                end)
            end
            return resolved(rt, endpoint)
        end
    end
    local owner, failure = runtime:owned_server({ socket_path = published }):await()
    local closed, close_error
    if owner then
        closed, close_error = owner:close():await()
    end
    uv.spawn, uv.fs_lstat, uv.fs_unlink, uv.fs_link, servers.resolved =
        spawn, lstat, unlink, link, resolved
    local current = lstat(published)
    local public = runtime:connect({ socket_path = published }):await()
    local response = public and public:command({ "display-message", "-p", "#{pid}" }):await()
    local reachable = response and response.stdout == replacement:receipt().pid .. "\n"
    print(
        label
            .. ": old PID "
            .. tostring(original_pid)
            .. ", replacement PID "
            .. replacement:receipt().pid
    )
    print(label .. ": boundary " .. tostring(boundary) .. ", public unlinks " .. public_unlinks)
    print(label .. ": replacement public endpoint reachable " .. tostring(reachable == true))
    must(replacement:close():await())
    if rollback then
        assert(not owner and failure.code == "injected_bind" and bind_failures == 1)
    else
        must(closed, close_error)
    end
    assert(retired and injected, "probe must retire original child and publish replacement")
    assert(
        current and current.ino == replacement_stat.ino and current.dev == replacement_stat.dev,
        "cleanup removed the concurrent replacement endpoint"
    )
    assert(reachable, "replacement must answer through the published endpoint")
    assert(public_unlinks == 0, "cleanup must not unlink the shared publication")
    assert(lstat(private) == nil, "original private startup path must retire")
    assert(lstat(private:match("^(.*)/s$")) == nil, "original startup directory must retire")
end

local result, failure = adapter.run(function(runtime)
    local root = assert(os.getenv("LIBTMUX_TEST_ROOT"))
    -- Run rollback first when requested so both paths fail on the old source.
    local order = os.getenv("REPLACEMENT_ORDER") or "normal"
    if order == "rollback" then
        scenario(runtime, root, "rollback", true)
        scenario(runtime, root, "normal", false)
    else
        scenario(runtime, root, "normal", false)
        scenario(runtime, root, "rollback", true)
    end
    print("replacement cleanup normal + startup rollback PASS")
    return true
end)
assert(result, tostring(failure))
