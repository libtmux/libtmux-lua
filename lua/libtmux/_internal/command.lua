local errors = require("libtmux._internal.error")
local process = require("libtmux._internal.process")
local M = {}
local quoted_escapes = '[%z\001-\031\127-\255"$\\~]'

local function string_value(value, nonempty)
    return type(value) == "string"
        and (not nonempty or value ~= "")
        and not value:find("\000", 1, true)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function length(values, maximum)
    if not plain(values) then
        return nil
    end
    local count, last = 0, 0
    for key in next, values do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or (maximum and key > maximum) then
            return nil
        end
        count, last = count + 1, math.max(last, key)
    end
    if count == 0 or count ~= last then
        return nil
    end
    return count
end

local function invalid(code, message)
    return nil, errors.new(code, message, { operation = "command", effect = "not_sent" })
end

-- This is tmux program text, distinct from the outer process argv encoding below.
function M.prepare_program(input, compact)
    if not plain(input) then
        return invalid("invalid_program", "program must be a plain record")
    end
    for key in next, input do
        if key ~= "commands" and key ~= "source" then
            return invalid("invalid_program", "unknown program field")
        end
    end
    local commands, source = rawget(input, "commands"), rawget(input, "source")
    if (commands ~= nil) == (source ~= nil) then
        return invalid("invalid_program", "program needs exactly one of commands or source")
    end
    local maximum_bytes = 1048576
    if source ~= nil then
        if
            type(source) ~= "string"
            or #source > maximum_bytes
            or not string_value(source, false)
        then
            return invalid("invalid_program", "program source must be bounded NUL-free bytes")
        end
        return source
    end
    local count = length(commands, 1024)
    if not count then
        return invalid("invalid_program", "program needs from 1 to 1024 dense commands")
    end
    local copied, arguments, bytes = {}, 0, (count - 1) * 3
    for index = 1, count do
        local argv = rawget(commands, index)
        local argc = length(argv, 4096 - arguments)
        if not argc then
            return invalid(
                "invalid_program",
                "program needs dense argv within 4096 total arguments"
            )
        end
        arguments = arguments + argc
        bytes = bytes + argc - 1
        for argument = 1, argc do
            local value = rawget(argv, argument)
            if type(value) ~= "string" then
                return invalid("invalid_program", "program arguments must be strings")
            end
            local escaped = #value
            if compact then
                escaped = select(2, value:gsub(quoted_escapes, ""))
            end
            bytes = bytes + 2 + #value + escaped * 3
            if bytes > maximum_bytes then
                return invalid("invalid_program", "encoded program exceeds one MiB")
            end
        end
        local prepared = process.prepare(argv)
        if not prepared then
            return invalid("invalid_program", "program argv needs a name and NUL-free strings")
        end
        copied[index] = prepared.argv
    end
    local encoded = {}
    for index, argv in ipairs(copied) do
        local words = {}
        for argument, value in ipairs(argv) do
            words[argument] = '"'
                .. value:gsub(compact and quoted_escapes or ".", function(byte)
                    return string.format("\\%03o", byte:byte())
                end)
                .. '"'
        end
        encoded[index] = table.concat(words, " ")
    end
    return table.concat(encoded, " ; ")
end

function M.prepare(endpoint, commands)
    if not plain(endpoint) then
        return invalid("invalid_endpoint", "tmux endpoint must be a plain table")
    end
    for key in next, endpoint do
        if key ~= "binary" and key ~= "socket" and key ~= "config" and key ~= "no_start" then
            return invalid("invalid_endpoint", "unknown tmux endpoint field")
        end
    end
    local binary = rawget(endpoint, "binary")
    if binary == nil then
        binary = "tmux"
    end
    local socket, config = rawget(endpoint, "socket"), rawget(endpoint, "config")
    local no_start = rawget(endpoint, "no_start")
    if
        not string_value(binary, true)
        or not string_value(socket, true)
        or (config ~= nil and not string_value(config, true))
        or (no_start ~= nil and type(no_start) ~= "boolean")
    then
        return invalid(
            "invalid_endpoint",
            "tmux endpoint needs NUL-free executable and socket paths"
        )
    end
    local count = length(commands)
    if not count then
        return invalid("invalid_command", "tmux commands must be a nonempty plain sequence")
    end
    local result = { binary, "-S", socket, "-u" }
    if config then
        result[#result + 1], result[#result + 2] = "-f", config
    end
    if no_start then
        result[#result + 1] = "-N"
    end
    result[#result + 1] = "--"
    for index = 1, count do
        local argv = rawget(commands, index)
        local argc = length(argv)
        if not argc then
            return invalid("invalid_command", "tmux command argv must be a nonempty plain sequence")
        end
        if index > 1 then
            result[#result + 1] = ";"
        end
        for argument = 1, argc do
            local value = rawget(argv, argument)
            if not string_value(value, argument == 1) then
                return invalid("invalid_command", "tmux command argv needs NUL-free strings")
            end
            -- tmux removes one backslash immediately before a terminal semicolon.
            if value:sub(-1) == ";" then
                value = value:sub(1, -2) .. "\\;"
            end
            result[#result + 1] = value
        end
    end
    return result
end

function M.group(runtime, endpoint, commands, options)
    local argv, err = M.prepare(endpoint, commands)
    if not argv then
        return runtime:_request({
            bytes = 0,
            start = function(settle, retire)
                settle(nil, err)
                retire()
            end,
        })
    end
    -- A client result has no reliable member attribution, including after WAIT.
    return process.execute(runtime, argv, options)
end

function M.execute(runtime, endpoint, argv, options)
    return M.group(runtime, endpoint, { argv }, options)
end

return M
