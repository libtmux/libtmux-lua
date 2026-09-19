local query = require("libtmux._internal.query")
local M = {}
local VERSION = "libtmux.where/v1"
local MAX_BYTES, MAX_STRINGS, MAX_NODES, MAX_DEPTH = 524288, 65536, 4096, 32
local MAX_NUMBER = 9007199254740991

local function fail(code, message, path)
    error(query.error(code, message, path or "$json", "query.json"), 0)
end

local function structured(err)
    return type(err) == "table"
        and type(rawget(err, "code")) == "string"
        and type(rawget(err, "message")) == "string"
        and type(rawget(err, "path")) == "string"
end

local function utf8(value, path)
    local index = 1
    while index <= #value do
        local first = value:byte(index)
        local count, minimum, maximum = 0, 128, 191
        if first >= 194 and first <= 223 then
            count = 1
        elseif first >= 224 and first <= 239 then
            count = 2
            minimum = first == 224 and 160 or 128
            maximum = first == 237 and 159 or 191
        elseif first >= 240 and first <= 244 then
            count = 3
            minimum = first == 240 and 144 or 128
            maximum = first == 244 and 143 or 191
        elseif first >= 128 then
            fail("invalid_json", "JSON strings must contain valid UTF-8", path)
        end
        if count > 0 then
            local second = value:byte(index + 1)
            if not second or second < minimum or second > maximum then
                fail("invalid_json", "JSON strings must contain valid UTF-8", path)
            end
            for offset = 2, count do
                local byte = value:byte(index + offset)
                if not byte or byte < 128 or byte > 191 then
                    fail("invalid_json", "JSON strings must contain valid UTF-8", path)
                end
            end
        end
        index = index + count + 1
    end
end

local function number(value, path)
    if type(value) ~= "number" or value ~= value or math.abs(value) > MAX_NUMBER then
        fail("invalid_json", "JSON numbers must be finite and within the portable range", path)
    end
end

local function budget()
    local nodes, strings = 0, 0
    return function(value, depth, path)
        nodes = nodes + 1
        if nodes > MAX_NODES or depth > MAX_DEPTH then
            fail("query_limit", "JSON exceeds its node or depth limit", path)
        end
        if type(value) == "string" then
            strings = strings + #value
            if strings > MAX_STRINGS then
                fail("query_limit", "JSON exceeds its aggregate string limit", path)
            end
            utf8(value, path)
        elseif type(value) == "number" then
            number(value, path)
        end
    end
end

local function codec_methods(codec)
    if
        type(codec) ~= "table"
        or getmetatable(codec) ~= nil
        or type(rawget(codec, "encode")) ~= "function"
        or type(rawget(codec, "newparser")) ~= "function"
    then
        fail("invalid_codec", "supply an explicit lunajson-compatible encoder and SAX parser")
    end
    return codec.encode, codec.newparser
end

local function decode(text, newparser)
    if type(text) ~= "string" then
        fail("invalid_json", "JSON input must be a string")
    end
    if #text > MAX_BYTES then
        fail("query_limit", "JSON input exceeds 524288 bytes")
    end
    local account, stack, kinds = budget(), {}, {}
    local root, root_set, parser
    local function attach(value)
        local frame = stack[#stack]
        if not frame then
            if root_set then
                fail("invalid_json", "JSON must contain one value")
            end
            root, root_set = value, true
        elseif frame.kind == "array" then
            frame.value[#frame.value + 1] = value
        else
            if frame.key == nil then
                fail("invalid_json", "JSON object value has no key")
            end
            frame.value[frame.key], frame.key = value, nil
        end
    end
    local function start(kind)
        account(false, #stack + 1)
        local value = {}
        kinds[value] = kind
        attach(value)
        stack[#stack + 1] = { kind = kind, value = value, seen = {} }
    end
    local function finish(kind)
        local frame = stack[#stack]
        if not frame or frame.kind ~= kind or frame.key ~= nil then
            fail("invalid_json", "JSON container is incomplete")
        end
        stack[#stack] = nil
    end
    local function scalar(value)
        account(value, #stack + 1)
        attach(value)
    end
    local callbacks = {
        startobject = function()
            start("object")
        end,
        endobject = function()
            finish("object")
        end,
        startarray = function()
            start("array")
        end,
        endarray = function()
            finish("array")
        end,
        key = function(key)
            account(key, #stack + 1)
            local frame = stack[#stack]
            if
                type(key) ~= "string"
                or not frame
                or frame.kind ~= "object"
                or frame.key ~= nil
                or frame.seen[key]
            then
                fail("invalid_json", "JSON object keys must be unique strings")
            end
            frame.seen[key], frame.key = true, key
        end,
        string = scalar,
        boolean = scalar,
        null = function()
            scalar(query.NULL)
        end,
        number = function(value)
            number(value)
            if value == 0 then
                local last = parser.tellpos() - 1
                local first = last
                while first > 0 and text:sub(first, first):match("[0-9eE.+-]") do
                    first = first - 1
                end
                local mantissa = text:sub(first + 1, last):match("^[^eE]+")
                if mantissa and mantissa:find("[1-9]") then
                    fail("invalid_json", "JSON number underflows to zero")
                end
            end
            scalar(value)
        end,
    }
    local ok, result = pcall(newparser, text, callbacks)
    if not ok then
        fail("codec_error", "JSON parser construction failed")
    end
    parser = result
    if
        type(parser) ~= "table"
        or type(parser.run) ~= "function"
        or type(parser.tellpos) ~= "function"
    then
        fail("codec_error", "JSON codec returned an invalid SAX parser")
    end
    ok, result = pcall(parser.run)
    if not ok then
        if structured(result) then
            error(result, 0)
        elseif type(result) == "string" and result:find("parse error at ", 1, true) then
            fail("invalid_json", "JSON syntax is malformed")
        end
        fail("codec_error", "JSON parser failed")
    end
    local position
    ok, position = pcall(parser.tellpos)
    if
        not ok
        or type(position) ~= "number"
        or position % 1 ~= 0
        or position < 1
        or position > #text + 1
    then
        fail("codec_error", "JSON parser returned an invalid input position")
    end
    if not root_set or #stack ~= 0 or not text:sub(position):match("^[ \t\r\n]*$") then
        fail("invalid_json", "JSON must contain one complete value and no trailing data")
    end
    return root, kinds
end

local function transform(schema, criteria, kinds, account, null)
    local function container(value, kind, depth, path)
        if kinds and kinds[value] ~= kind then
            fail("invalid_wire", "expected a JSON " .. kind, path)
        end
        if account then
            account(value, depth, path)
        end
        return {}
    end
    local function scalar(value, depth, path)
        if account then
            account(value, depth, path)
        end
        return rawequal(value, query.NULL) and null or value
    end
    local function key(value, depth, path)
        if account then
            account(value, depth, path)
        end
    end
    local visit
    local function array(value, definition, depth, path)
        local copied = container(value, "array", depth, path)
        for index, item in ipairs(value) do
            local at = path .. "." .. index
            if definition then
                copied[index] = visit(definition, item, depth + 1, at)
            else
                copied[index] = scalar(item, depth + 1, at)
            end
        end
        if not kinds then
            copied[0] = #value
        end
        return copied
    end
    visit = function(definition, value, depth, path)
        local copied = container(value, "object", depth, path)
        for name, operand in pairs(value) do
            local at = path .. "." .. name
            key(name, depth + 1, at)
            if name == "AND" or name == "OR" then
                copied[name] = array(operand, definition, depth + 1, at)
            elseif name == "NOT" then
                copied[name] = visit(definition, operand, depth + 1, at)
            elseif type(operand) ~= "table" or rawequal(operand, query.NULL) then
                copied[name] = scalar(operand, depth + 1, at)
            else
                local operators = container(operand, "object", depth + 1, at)
                copied[name] = operators
                local relation = definition.relations[name]
                for operator, item in pairs(operand) do
                    local here = at .. "." .. operator
                    key(operator, depth + 2, here)
                    if relation and not rawequal(item, query.NULL) then
                        operators[operator] = visit(relation.schema, item, depth + 2, here)
                    elseif operator == "one_of" or operator == "none_of" then
                        operators[operator] = array(item, nil, depth + 2, here)
                    else
                        operators[operator] = scalar(item, depth + 2, here)
                    end
                end
            end
        end
        return copied
    end
    return visit(schema, criteria, 2, "$json.where")
end

local function guarded(fn)
    local ok, value = pcall(fn)
    if ok then
        return value
    end
    if structured(value) then
        return nil, value
    end
    return nil, query.error("codec_error", "JSON codec failed", "$json", "query.json")
end

function M.encode(schema, criteria, codec)
    return guarded(function()
        local encode = codec_methods(codec)
        local compiled = query.compile(schema, criteria)
        local account, null = budget(), {}
        account({}, 1, "$json")
        account("version", 2, "$json.version")
        account(VERSION, 2, "$json.version")
        account("where", 2, "$json.where")
        local value = {
            version = VERSION,
            where = transform(compiled.schema, criteria, nil, account, null),
        }
        local ok, encoded = pcall(encode, value, null)
        if not ok or type(encoded) ~= "string" then
            fail("codec_error", "JSON encoder failed")
        end
        if #encoded > MAX_BYTES then
            fail("query_limit", "encoded JSON exceeds 524288 bytes")
        end
        return encoded
    end)
end

function M.decode(schema, text, codec)
    return guarded(function()
        local _, newparser = codec_methods(codec)
        schema = query.schema(schema)
        local value, kinds = decode(text, newparser)
        if kinds[value] ~= "object" then
            fail("invalid_wire", "query JSON envelope must be an object")
        end
        for key in pairs(value) do
            if key ~= "version" and key ~= "where" then
                fail("invalid_wire", "unknown query JSON envelope member")
            end
        end
        if type(value.version) ~= "string" or value.where == nil then
            fail("invalid_wire", "query JSON requires version and where members")
        end
        if value.version ~= VERSION then
            fail("unsupported_wire_version", "unsupported query JSON profile version")
        end
        query.compile(schema, value.where)
        return transform(schema, value.where, kinds, nil, query.NULL)
    end)
end

return M
