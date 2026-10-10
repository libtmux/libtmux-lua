local errors = require("libtmux._internal.error")
local command = require("libtmux._internal.command")
local M = {}

local function failure(message, cause)
    return nil,
        errors.new("invalid_endpoint", message, {
            operation = "connect",
            effect = "not_sent",
            cause = cause,
        })
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function text(value)
    return type(value) == "string" and not value:find("\000", 1, true)
end

local function absolute(value)
    return text(value) and value:sub(1, 1) == "/" and #value <= 4096
end

local function present(value)
    return value ~= nil and value ~= ""
end

local function name(value)
    return text(value)
        and value ~= ""
        and value ~= "."
        and value ~= ".."
        and not value:find("/", 1, true)
        and not value:find("\\", 1, true)
end

local function context(value)
    if not text(value) then
        return failure("TMUX must contain a socket path, PID and session ID")
    end
    local path, pid, session = value:match("^(.*),([^,]*),([^,]*)$")
    if not absolute(path) or not pid:match("^[0-9]+$") or not pid:find("[1-9]") then
        return failure("TMUX needs an absolute socket path and positive decimal PID")
    end
    if session ~= "-1" and not session:match("^%$?[0-9]+$") then
        return failure("TMUX needs a nonnegative decimal session ID or -1")
    end
    return { socket = path, pid = pid, session = session }
end

local function environment(uv, overrides)
    if not uv or type(uv.os_environ) ~= "function" then
        return failure("connection requires a host environment snapshot")
    end
    local captured, cause = uv.os_environ()
    if not captured then
        return failure("cannot capture the client environment", cause)
    end
    local copied = {}
    for key, value in pairs(captured) do
        copied[key] = value
    end
    if overrides ~= nil then
        if not plain(overrides) then
            return failure("client_env must be a plain environment override map")
        end
        for key, value in next, overrides do
            if
                not text(key)
                or key == ""
                or key:find("=", 1, true)
                or (value ~= false and not text(value))
            then
                return failure("client_env needs NUL-free names and string values or false")
            end
            copied[key] = value ~= false and value or nil
        end
    end
    return copied
end

local function environment_values(entries)
    local values = {}
    for _, entry in ipairs(entries) do
        local key, value = entry:match("^([^=]+)=(.*)$")
        -- getenv uses the first entry, including an empty value.
        if key and values[key] == nil then
            values[key] = value
        end
    end
    return values
end

local function socket_root(env)
    return present(env.TMUX_TMPDIR) and env.TMUX_TMPDIR or "/tmp"
end

function M.socket_root(entries)
    return socket_root(environment_values(entries))
end

local function explicit_environment(entries)
    local prepared, err = command.process_options({}, { env = entries })
    if not prepared then
        return failure("env must be a dense sequence of NUL-free environment entries", err)
    end
    local captured, copied = environment_values(prepared.env), {}
    for _, entry in ipairs(prepared.env) do
        local key = entry:match("^([^=]+)=")
        -- Match getenv's first entry while preserving the original full sequence.
        if key ~= "TMUX" and key ~= "TMUX_PANE" then
            copied[#copied + 1] = entry
        end
    end
    return captured, nil, copied
end

local function executable(uv, env)
    local search = env.PATH or "/usr/bin:/bin"
    for component in (search .. ":"):gmatch("(.-):") do
        local directory = component
        if directory:sub(1, 1) ~= "/" then
            local cwd, cause = uv.cwd()
            if not cwd then
                return failure("cannot resolve relative executable search directory", cause)
            end
            directory = cwd .. "/" .. directory
        end
        local candidate = directory .. "/tmux"
        local stat = uv.fs_stat(candidate)
        if stat and stat.type == "file" and uv.fs_access(candidate, "X") then
            return candidate
        end
    end
    return failure("cannot find tmux in the captured client PATH")
end

function M.resolve(uv, options)
    options = options == nil and {} or options
    if not plain(options) then
        return failure("connection options must be a plain record")
    end
    local allowed = {
        binary = true,
        socket_path = true,
        socket_name = true,
        config_path = true,
        client_env = true,
        env = true,
    }
    for key in next, options do
        if not allowed[key] then
            return failure("unknown connection option")
        end
    end
    if options.socket_path ~= nil and options.socket_name ~= nil then
        return failure("socket_path and socket_name are mutually exclusive")
    end
    if options.env ~= nil and options.client_env ~= nil then
        return failure("env supplies the complete environment; choose env or client_env")
    end
    local env, err, explicit_entries
    if options.env ~= nil then
        env, err, explicit_entries = explicit_environment(options.env)
    else
        env, err = environment(uv, options.client_env)
    end
    if not env then
        return nil, err
    end
    local path, selected_name, selected_context
    if options.socket_path ~= nil then
        path = options.socket_path
    elseif options.socket_name ~= nil then
        selected_name = options.socket_name
    elseif present(env.LIBTMUX_SOCKET_PATH) then
        path = env.LIBTMUX_SOCKET_PATH
    elseif present(env.LIBTMUX_SOCKET_NAME) then
        selected_name = env.LIBTMUX_SOCKET_NAME
    elseif present(env.TMUX) then
        selected_context, err = context(env.TMUX)
        if not selected_context then
            return nil, err
        end
        path = selected_context.socket
        selected_context.pane = env.TMUX_PANE
    else
        selected_name = "default"
    end
    local root, uid
    if selected_name ~= nil then
        if not name(selected_name) then
            return failure("socket_name must be a nonempty leaf name")
        end
        root = socket_root(env)
        if not absolute(root) then
            return failure("TMUX_TMPDIR must be an absolute NUL-free path")
        end
        uid = uv.getuid()
        if type(uid) ~= "number" or uid < 0 or uid % 1 ~= 0 then
            return failure("cannot determine the current UID for the named socket")
        end
        -- Keep components for filesystem resolution, including missing/.. and symlink/...
        path = root .. "/tmux-" .. string.format("%.0f", uid) .. "/" .. selected_name
    end
    if not absolute(path) or path:sub(-1) == "/" then
        return failure("socket_path must be an absolute NUL-free socket path")
    end
    local binary = options.binary
    if binary == nil then
        binary, err = executable(uv, env)
        if not binary then
            return nil, err
        end
    end
    if
        not absolute(binary) or (options.config_path ~= nil and not absolute(options.config_path))
    then
        return failure("binary and config_path must be absolute NUL-free paths")
    end
    env.TMUX, env.TMUX_PANE = nil, nil
    local entries = explicit_entries or {}
    if not explicit_entries then
        for key, value in pairs(env) do
            entries[#entries + 1] = key .. "=" .. value
        end
        table.sort(entries)
    end
    return {
        binary = binary,
        socket = path,
        config = options.config_path or "/dev/null",
        env = entries,
        root = root,
        uid = uid,
        context = selected_context,
    }
end

return M
