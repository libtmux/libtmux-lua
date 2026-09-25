local codec = require("libtmux._internal.codec")
local errors = require("libtmux._internal.error")
local identity = require("libtmux._internal.identity")
local process = require("libtmux._internal.process")
local execution = require("libtmux._internal.execution")
local M = {}
local commands = { session = "new-session", window = "new-window", pane = "split-window" }
local creation_format =
    assert(codec.format({ "session_id", "window_id", "pane_id", "window_index" }))
local MAX_INPUT = 1024 * 1024

local function failure(code, message, operation, details)
    details = details or {}
    details.operation, details.effect = operation, details.effect or "not_sent"
    return errors.new(code, message, details)
end

local function invalid(message)
    error(failure("invalid_options", message, "create"), 0)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function bytes(value, empty, maximum)
    return type(value) == "string"
        and (empty or #value > 0)
        and #value <= (maximum or 65536)
        and not value:find("\000", 1, true)
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

local function literal(value)
    return (value:gsub("#", "##"))
end

function M.append_launch(argv, options, reject)
    local function flag(name, value)
        argv[#argv + 1] = name
        if value ~= nil then
            argv[#argv + 1] = tostring(value)
        end
    end
    if options.cwd ~= nil then
        if not bytes(options.cwd, false, 4096) or options.cwd:sub(1, 1) ~= "/" then
            reject("cwd must be an absolute NUL-free path")
        end
        flag("-c", literal(options.cwd))
    end
    if options.environment ~= nil then
        if not plain(options.environment) then
            reject("environment must be a plain string map")
        end
        local names = {}
        for name, value in next, options.environment do
            if
                not bytes(name, false, 256)
                or not name:match("^[A-Za-z_][A-Za-z0-9_]*$")
                or not bytes(value, true)
            then
                reject("environment needs portable variable names and NUL-free string values")
            end
            names[#names + 1] = name
            if #names > 128 then
                reject("environment exceeds 128 entries")
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            flag("-e", name .. "=" .. options.environment[name])
        end
    end
    if options.argv ~= nil and options.shell ~= nil then
        reject("argv and shell are mutually exclusive")
    end
    flag("--")
    if options.argv ~= nil then
        if not plain(options.argv) then
            reject("argv must be a plain dense sequence")
        end
        local count = 0
        for key in next, options.argv do
            count = count + 1
            if not integer(key, 1, 1024) or count > 1024 then
                reject("argv exceeds its argument limit")
            end
        end
        if count == 0 then
            reject("argv must not be empty")
        end
        -- tmux treats one argument as shell text; env ensures literal execvp semantics.
        if count == 1 then
            local executable = rawget(options.argv, 1)
            if type(executable) == "string" and executable:find("=", 1, true) then
                reject("singleton argv executable cannot contain '='; use explicit shell text")
            end
            flag("/usr/bin/env")
            flag("--")
        end
        for index = 1, count do
            local value = rawget(options.argv, index)
            if not bytes(value, index > 1) then
                reject("argv needs bounded NUL-free strings without holes")
            end
            argv[#argv + 1] = value
        end
    elseif options.shell ~= nil then
        if not bytes(options.shell, false) then
            reject("shell must be explicit nonempty NUL-free text")
        end
        argv[#argv + 1] = options.shell
    end
end

local function current(state, parent)
    if state.closed then
        return nil, failure("closed", "server handle is closed", "create")
    end
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    if not parent then
        return generation
    end
    local ref
    ref, err = identity.inspect(generation, parent)
    if not ref then
        return nil, err
    end
    return generation, ref
end

local function prepare(runtime, kind, ref, options)
    if not commands[kind] then
        invalid("unknown creation kind")
    end
    if options == nil then
        options = {}
    end
    if not plain(options) then
        invalid("creation options must be a plain record")
    end
    local allowed = { cwd = true, argv = true, shell = true, environment = true, process = true }
    if kind == "session" then
        allowed.name, allowed.window_name, allowed.width, allowed.height = true, true, true, true
    elseif kind == "window" then
        allowed.name, allowed.index, allowed.select = true, true, true
    else
        allowed.direction, allowed.size, allowed.percent, allowed.full_size, allowed.select =
            true, true, true, true, true
    end
    for name in next, options do
        if not allowed[name] then
            invalid("unknown creation option")
        end
    end
    if
        kind ~= "session" and (not ref or ref.kind ~= (kind == "window" and "session" or "pane"))
    then
        error(
            failure(
                "invalid_target",
                "creation requires a session or pane parent of the matching kind",
                "create"
            ),
            0
        )
    end
    local argv = { commands[kind] }
    local function flag(name, value)
        argv[#argv + 1] = name
        if value ~= nil then
            argv[#argv + 1] = tostring(value)
        end
    end
    if options.select ~= nil and type(options.select) ~= "boolean" then
        invalid("select must be boolean")
    end
    if not options.select then
        flag("-d")
    end
    flag("-P")
    flag("-F", creation_format)
    if options.name ~= nil then
        if not bytes(options.name, false, 1024) then
            invalid("name must be a bounded NUL-free string")
        end
        if kind == "session" and options.name:find("[.:\001-\031\127]") then
            invalid("session name cannot contain dots, colons or control bytes")
        end
        flag(kind == "session" and "-s" or "-n", literal(options.name))
    end
    if options.window_name ~= nil then
        if not bytes(options.window_name, false, 1024) then
            invalid("window name must be a bounded NUL-free string")
        end
        flag("-n", literal(options.window_name))
    end
    for _, pair in ipairs({ { "width", "-x" }, { "height", "-y" } }) do
        local value = options[pair[1]]
        if value ~= nil then
            if not integer(value, 1, 65535) then
                invalid("session dimensions must be integers from 1 to 65535")
            end
            flag(pair[2], string.format("%.0f", value))
        end
    end
    if kind == "window" then
        if options.index ~= nil and not integer(options.index, 0, 2147483647) then
            invalid("window index must be a nonnegative integer")
        end
        flag("-t", ref.id .. ":" .. (options.index and string.format("%.0f", options.index) or ""))
    elseif kind == "pane" then
        flag("-t", ref.id)
        local direction = options.direction or "down"
        if
            direction ~= "up"
            and direction ~= "down"
            and direction ~= "left"
            and direction ~= "right"
        then
            invalid("split direction must be up, down, left or right")
        end
        flag((direction == "left" or direction == "right") and "-h" or "-v")
        if direction == "left" or direction == "up" then
            flag("-b")
        end
        if options.full_size ~= nil and type(options.full_size) ~= "boolean" then
            invalid("full_size must be boolean")
        end
        if options.full_size then
            flag("-f")
        end
        if options.size ~= nil and options.percent ~= nil then
            invalid("split size and percent are mutually exclusive")
        end
        if options.size ~= nil then
            if not integer(options.size, 1, 65535) then
                invalid("split size must be a positive bounded integer")
            end
            flag("-l", string.format("%.0f", options.size))
        elseif options.percent ~= nil then
            if not integer(options.percent, 1, 99) then
                invalid("split percent must be an integer from 1 to 99")
            end
            flag("-l", string.format("%.0f%%", options.percent))
        end
    end
    M.append_launch(argv, options, invalid)
    if options.process ~= nil then
        if not plain(options.process) then
            invalid("process options must be a plain record")
        end
        local accepted = {
            timeout = true,
            deadline = true,
            max_output_bytes = true,
            kill_timeout = true,
            drain_timeout = true,
        }
        for name in next, options.process do
            if not accepted[name] then
                invalid("unsupported creation process option")
            end
        end
    end
    local copied, configured, input_bytes =
        execution.prepare(runtime, { argv }, options.process, false)
    if not copied then
        error(configured, 0)
    end
    local plan = { argv = copied[1], options = configured, bytes = input_bytes }
    if plan.bytes > MAX_INPUT then
        invalid("creation input exceeds one MiB")
    end
    plan.cwd = options.cwd
    return plan
end

function M.directory(state, path, operation)
    operation = operation or "create.cwd"
    return state.runtime:_request({
        bytes = #path,
        operation = operation,
        effect = "not_sent",
        start = function(settle, retire)
            local uv = state.runtime._driver.uv
            if not uv or type(uv.fs_stat) ~= "function" then
                settle(
                    nil,
                    failure(
                        "unsupported",
                        "runtime cannot validate the working directory",
                        operation
                    )
                )
                retire()
                return
            end
            local called = false
            local function done(err, stat)
                if called then
                    return
                end
                called = true
                if err or not stat or stat.type ~= "directory" then
                    settle(
                        nil,
                        failure(
                            "invalid_directory",
                            "working directory is unavailable",
                            operation,
                            { cause = err }
                        )
                    )
                else
                    settle(true)
                end
                retire()
            end
            local ok, native, err = pcall(uv.fs_stat, path, done)
            if not called and (not ok or not native) then
                done(ok and err or native)
            end
            return function() end
        end,
    })
end

local function receipt(state, generation, kind, parent, result, wrap)
    local rows, err = codec.decode(result.stdout, 4, { max_rows = 1, max_bytes = 16384 })
    local row = rows and rows[1]
    if
        not row
        or #rows ~= 1
        or not row[1]:match("^%$%d+$")
        or not row[2]:match("^@%d+$")
        or not row[3]:match("^%%%d+$")
        or not row[4]:match("^%d+$")
        or not integer(tonumber(row[4]), 0, 2147483647)
        or kind == "window" and row[1] ~= parent.id
    then
        return nil,
            failure(
                "invalid_result",
                "creation did not return one valid identity tuple",
                commands[kind],
                { effect = "completed", partial = result, cause = err }
            )
    end
    local refs = {
        session = { kind = "session", id = row[1], generation = generation },
        window = { kind = "window", id = row[2], generation = generation },
        pane = { kind = "pane", id = row[3], generation = generation },
        window_link = {
            kind = "window_link",
            session_id = row[1],
            window_id = row[2],
            index = tonumber(row[4]),
            generation = generation,
        },
    }
    local created = {
        created = kind == "session" and { "session", "window", "pane", "window_link" }
            or kind == "window" and { "window", "pane", "window_link" }
            or { "pane" },
    }
    for name, ref in pairs(refs) do
        created[name], err = wrap(state, ref)
        if not created[name] then
            return nil,
                failure(
                    "invalid_result",
                    "created identity is no longer available",
                    commands[kind],
                    { effect = "completed", partial = result, cause = err }
                )
        end
    end
    return created
end

function M.create(state, parent, kind, options, wrap)
    local generation, ref = current(state, parent)
    local plan, validation_error
    if not generation then
        validation_error = ref
    else
        local ok, value = pcall(prepare, state.runtime, kind, ref, options)
        if ok then
            plan = value
        else
            validation_error = value
        end
    end
    local request = state.runtime:_operation(function(_, operation)
        if not plan then
            return nil, validation_error
        end
        local now, err = current(state, parent)
        if not now then
            return nil, err
        end
        if not rawequal(generation, now) then
            return nil,
                failure(
                    "stale_generation",
                    "server generation changed before creation",
                    commands[kind]
                )
        end
        if plan.cwd then
            local valid
            valid, err = M.directory(state, plan.cwd):await()
            if not valid then
                return nil, err
            end
        end
        operation:_set_effect("unknown")
        local result
        result, err = state.bound:execute(plan.argv, plan.options):await()
        result, err = process.retain_output(operation, result, err, commands[kind])
        if not result then
            return nil, err
        end
        return receipt(state, generation, kind, ref, result, wrap)
    end, { operation = commands[kind] or "create", effect = "not_sent" })
    if plan and not request:is_settled() then
        local accepted, cause = request:_retain(plan.bytes)
        if not accepted then
            request:cancel(
                failure(
                    "queue_full",
                    "creation input exceeds runtime byte capacity",
                    commands[kind],
                    { cause = cause }
                )
            )
        end
    end
    return request
end

---@class libtmux.CreationProcessOptions
---@field timeout? number
---@field deadline? number
---@field max_output_bytes? integer
---@field drain_timeout? integer
---@field kill_timeout? integer

---@class libtmux.CreationOptions
---@field cwd? string Absolute working directory.
---@field argv? string[] Literal command arguments; mutually exclusive with shell.
---@field shell? string Explicit shell program.
---@field environment? table<string,string> Environment for the created scope.
---@field process? libtmux.CreationProcessOptions

---@class libtmux.NewSessionOptions: libtmux.CreationOptions
---@field name? string
---@field window_name? string
---@field width? integer
---@field height? integer

---@class libtmux.NewWindowOptions: libtmux.CreationOptions
---@field name? string
---@field index? integer
---@field select? boolean Defaults to false.

---@class libtmux.SplitOptions: libtmux.CreationOptions
---@field direction? "up"|"down"|"left"|"right" Defaults to down.
---@field size? integer
---@field percent? integer Mutually exclusive with size.
---@field full_size? boolean
---@field select? boolean Defaults to false.

---@class libtmux.Creation
---@field session libtmux.Session
---@field window libtmux.Window
---@field pane libtmux.Pane
---@field window_link libtmux.WindowLink
---@field created string[] Names of newly created entities in this receipt.

return M
