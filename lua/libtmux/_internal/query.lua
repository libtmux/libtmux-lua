local M = {}
local error_mt = {
    __tostring = function(err)
        return err.operation .. ": " .. err.message .. " (" .. err.path .. ")"
    end,
}

---@param code string
---@param message string
---@param path? string
---@param operation? string
---@return libtmux.QueryError
function M.error(code, message, path, operation)
    return setmetatable({
        code = code,
        operation = operation or "query",
        message = message,
        path = path or "$",
    }, error_mt)
end

---@param code string
---@param message string
---@param path? string
---Raise a structured error; this function does not return.
function M.fail(code, message, path)
    error(M.error(code, message, path), 0)
end

---@type libtmux.Null
local NULL = setmetatable({}, {
    __tostring = function()
        return "NULL"
    end,
    __newindex = function()
        M.fail("invalid_data", "NULL cannot be modified", "$")
    end,
    __metatable = "libtmux.NULL",
})
M.NULL = NULL

function M.sequence(value, path, code, allow_metatable)
    code = code or "invalid_sequence"
    if type(value) ~= "table" or (not allow_metatable and getmetatable(value) ~= nil) then
        M.fail(code, "expected a dense sequence", path)
    end
    local count = 0
    for key in next, value do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            M.fail(code, "expected positive integer sequence keys", path)
        end
        count = count + 1
    end
    for index = 1, count do
        if rawget(value, index) == nil then
            M.fail(code, "sequence contains a hole", path)
        end
    end
    return count
end

local function object(value, path, code)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        M.fail(code, "expected a plain table", path)
    end
    for key in next, value do
        if type(key) ~= "string" then
            M.fail(code, "expected string keys", path)
        end
    end
end

local function keys(value, allowed, path)
    object(value, path, "invalid_schema")
    for key in next, value do
        if not allowed[key] then
            M.fail("invalid_schema", "unknown schema key " .. key, path)
        end
    end
end

local normalized_schemas = setmetatable({}, { __mode = "k" })
local schema_keys = { fields = true, relations = true, name = true }
local field_keys = { type = true, nullable = true, supported = true }
local relation_keys = { cardinality = true, schema = true, nullable = true, supported = true }
local scalar_types = { string = true, number = true, boolean = true }

local function schema_flag(definition, flag, path)
    if definition[flag] ~= nil and type(definition[flag]) ~= "boolean" then
        M.fail("invalid_schema", flag .. " must be boolean", path)
    end
end

function M.schema(value)
    if normalized_schemas[value] then
        return value
    end
    local seen, nodes = {}, 0
    local function normalize(input, path, depth)
        if seen[input] then
            return seen[input]
        end
        if depth > 32 then
            M.fail("invalid_schema", "schema nesting exceeds 32", path)
        end
        keys(input, schema_keys, path)
        nodes = nodes + 1
        if nodes > 4096 then
            M.fail("invalid_schema", "schema exceeds 4096 nodes", path)
        end
        if input.fields == nil and input.relations == nil then
            M.fail("invalid_schema", "an explicit fields or relations table is required", path)
        end
        if input.name ~= nil and type(input.name) ~= "string" then
            M.fail("invalid_schema", "schema name must be a string", path)
        end
        local result = { name = input.name, fields = {}, relations = {} }
        seen[input] = result
        for _, group in ipairs({ "fields", "relations" }) do
            local definitions = input[group]
            if definitions == nil then
                definitions = {}
            end
            object(definitions, path .. "." .. group, "invalid_schema")
            for name, definition in pairs(definitions) do
                local at = path .. "." .. group .. "." .. name
                if not name:match("^[a-z][a-z0-9_]*$") then
                    M.fail("invalid_schema", "field and relation names must be snake_case", at)
                end
                if group == "relations" and result.fields[name] then
                    M.fail("invalid_schema", "field and relation names overlap", at)
                end
                keys(definition, group == "fields" and field_keys or relation_keys, at)
                schema_flag(definition, "nullable", at)
                schema_flag(definition, "supported", at)
                nodes = nodes + 1
                if nodes > 4096 then
                    M.fail("invalid_schema", "schema exceeds 4096 nodes", at)
                end
                local copied = {
                    nullable = definition.nullable == true,
                    supported = definition.supported ~= false,
                }
                if group == "fields" then
                    if not scalar_types[definition.type] then
                        M.fail(
                            "invalid_schema",
                            "field type must be string, number, or boolean",
                            at
                        )
                    end
                    copied.type = definition.type
                else
                    if definition.cardinality ~= "one" and definition.cardinality ~= "many" then
                        M.fail("invalid_schema", "relation cardinality must be one or many", at)
                    end
                    if definition.cardinality == "many" and copied.nullable then
                        M.fail("invalid_schema", "to-many relations cannot be nullable", at)
                    end
                    copied.cardinality = definition.cardinality
                    copied.schema = normalize(definition.schema, at .. ".schema", depth + 1)
                end
                result[group][name] = copied
            end
        end
        normalized_schemas[result] = true
        return result
    end
    return normalize(value, "$schema", 1)
end

local function finite(value)
    return value == value and value ~= math.huge and value ~= -math.huge
end

local function copy_criteria(input)
    local active, nodes, bytes, string_bytes = {}, 0, 0, 0
    local function visit(value, path, depth)
        nodes = nodes + 1
        bytes = bytes + 8
        if depth > 32 or nodes > 4096 or bytes > 524288 then
            M.fail("query_limit", "criteria exceed depth, node, or byte limits", path)
        end
        if rawequal(value, NULL) then
            return NULL
        end
        local kind = type(value)
        if kind == "string" then
            string_bytes = string_bytes + #value
            bytes = bytes + #value * 6
            if string_bytes > 65536 or bytes > 524288 then
                M.fail("query_limit", "criteria exceed string or byte limits", path)
            end
            return value
        elseif kind == "number" then
            if not finite(value) then
                M.fail("invalid_criteria", "numbers must be finite", path)
            end
            return value
        elseif kind == "boolean" then
            return value
        elseif kind ~= "table" then
            M.fail("invalid_criteria", "criteria must contain only data values", path)
        end
        if getmetatable(value) ~= nil then
            M.fail("invalid_criteria", "metatables are not permitted", path)
        end
        if active[value] then
            M.fail("invalid_criteria", "cyclic criteria are not permitted", path)
        end
        active[value] = true
        local result = {}
        for key, item in pairs(value) do
            if type(key) ~= "string" and type(key) ~= "number" then
                M.fail("invalid_criteria", "invalid criteria key", path)
            end
            visit(key, path, depth + 1)
            result[key] = visit(item, path .. "." .. tostring(key), depth + 1)
        end
        active[value] = nil
        return result
    end
    return visit(input, "$", 1)
end

local function scalar(value, field, path, code)
    if rawequal(value, NULL) then
        if not field.nullable then
            M.fail(code, "field is not nullable", path)
        end
    elseif type(value) ~= field.type or (type(value) == "number" and not finite(value)) then
        M.fail(code, "expected a finite " .. field.type .. " value", path)
    end
end

local operators = {
    eq = "scalar",
    ne = "scalar",
    one_of = "list",
    none_of = "list",
    lt = "number",
    lte = "number",
    gt = "number",
    gte = "number",
    contains = "string",
    starts_with = "string",
    ends_with = "string",
    is_null = "null",
}

local parse
local function field_node(name, definition, value, path)
    local terms = {}
    if rawequal(value, NULL) or type(value) ~= "table" then
        scalar(value, definition, path, "invalid_criteria")
        terms[1] = { operator = "eq", value = value }
    else
        object(value, path, "invalid_criteria")
        for operator, operand in pairs(value) do
            local at = path .. "." .. operator
            local kind = operators[operator]
            if kind == nil then
                M.fail("invalid_criteria", "unknown operator " .. operator, at)
            end
            if kind == "scalar" then
                scalar(operand, definition, at, "invalid_criteria")
            elseif kind == "list" then
                local count = M.sequence(operand, at, "invalid_criteria")
                if count > 1024 then
                    M.fail("query_limit", "membership exceeds 1024 values", at)
                end
                for index = 1, count do
                    scalar(operand[index], definition, at, "invalid_criteria")
                end
            elseif kind == "number" or kind == "string" then
                if definition.type ~= kind or type(operand) ~= kind then
                    M.fail(
                        "invalid_criteria",
                        operator .. " requires a " .. kind .. " field and operand",
                        at
                    )
                end
            elseif kind == "null" then
                if not definition.nullable or type(operand) ~= "boolean" then
                    M.fail("invalid_criteria", "is_null requires a nullable field and boolean", at)
                end
            end
            terms[#terms + 1] = { operator = operator, value = operand }
        end
        if #terms == 0 then
            M.fail("invalid_criteria", "field operators cannot be empty", path)
        end
    end
    return { kind = "field", name = name, definition = definition, terms = terms, path = path }
end

local function relation_node(name, definition, value, path)
    object(value, path, "invalid_criteria")
    local terms = {}
    for operator, operand in pairs(value) do
        local at = path .. "." .. operator
        if definition.cardinality == "many" then
            if operator ~= "some" and operator ~= "every" and operator ~= "none" then
                M.fail("invalid_criteria", "to-many relations require some, every, or none", at)
            end
        elseif operator ~= "is" and operator ~= "is_not" then
            M.fail("invalid_criteria", "to-one relations require is or is_not", at)
        end
        local node
        if rawequal(operand, NULL) then
            if definition.cardinality ~= "one" or not definition.nullable then
                M.fail("invalid_criteria", "NULL requires a nullable to-one relation", at)
            end
            node = NULL
        else
            node = parse(definition.schema, operand, at)
        end
        terms[#terms + 1] = { operator = operator, node = node }
    end
    if #terms == 0 then
        M.fail("invalid_criteria", "relation operators cannot be empty", path)
    end
    return { kind = "relation", name = name, definition = definition, terms = terms, path = path }
end

parse = function(schema, criteria, path)
    object(criteria, path, "invalid_criteria")
    local terms = {}
    for name, value in pairs(criteria) do
        local at = path .. "." .. name
        if name == "AND" or name == "OR" then
            local count = M.sequence(value, at, "invalid_criteria")
            local children = {}
            for index = 1, count do
                children[index] = parse(schema, value[index], at .. "." .. index)
            end
            terms[#terms + 1] = { kind = name, terms = children }
        elseif name == "NOT" then
            terms[#terms + 1] = { kind = "NOT", node = parse(schema, value, at) }
        else
            local field, relation = schema.fields[name], schema.relations[name]
            local definition = field or relation
            if definition == nil then
                return M.fail("invalid_criteria", "unknown field or relation " .. name, at)
            end
            if not definition.supported then
                M.fail("unsupported_field", "field or relation is unavailable", at)
            end
            terms[#terms + 1] = field and field_node(name, field, value, at)
                or relation_node(name, relation, value, at)
        end
    end
    return { kind = "AND", terms = terms }
end

function M.compile(schema, criteria)
    schema = M.schema(schema)
    return { schema = schema, node = parse(schema, copy_criteria(criteria), "$") }
end

function M.check_schema(schema, node)
    if node.kind == "AND" or node.kind == "OR" then
        for _, term in ipairs(node.terms) do
            M.check_schema(schema, term)
        end
    elseif node.kind == "NOT" then
        M.check_schema(schema, node.node)
    else
        local definition = node.kind == "field" and schema.fields[node.name]
            or schema.relations[node.name]
        if definition == nil then
            return M.fail(
                "invalid_schema",
                "compiled field or relation is missing from selection schema",
                node.path
            )
        end
        if not definition.supported then
            M.fail("unsupported_field", "field or relation is unavailable", node.path)
        end
        if
            definition.type ~= node.definition.type
            or definition.cardinality ~= node.definition.cardinality
            or definition.nullable ~= node.definition.nullable
        then
            M.fail(
                "invalid_schema",
                "compiled field or relation disagrees with selection schema",
                node.path
            )
        end
        if node.kind == "relation" then
            for _, term in ipairs(node.terms) do
                if not rawequal(term.node, NULL) then
                    M.check_schema(definition.schema, term.node)
                end
            end
        end
    end
end

local function record(value, path)
    if type(value) ~= "table" or rawequal(value, NULL) or getmetatable(value) ~= nil then
        M.fail("invalid_data", "expected a plain record", path)
    end
end

local function projection(row, node, path)
    if node.kind == "AND" or node.kind == "OR" then
        for _, term in ipairs(node.terms) do
            projection(row, term, path)
        end
    elseif node.kind == "NOT" then
        projection(row, node.node, path)
    else
        local value = rawget(row, node.name)
        local at = path .. "." .. node.name
        if value == nil then
            M.fail("unloaded_field", "required field or relation is not loaded", at)
        end
        if node.kind == "field" then
            scalar(value, node.definition, at, "invalid_data")
        elseif rawequal(value, NULL) then
            if not node.definition.nullable then
                M.fail("invalid_data", "relation is not nullable", at)
            end
        elseif node.definition.cardinality == "many" then
            local count = M.sequence(value, at, "invalid_data")
            for index = 1, count do
                local child_path = at .. "." .. index
                record(value[index], child_path)
                for _, term in ipairs(node.terms) do
                    projection(value[index], term.node, child_path)
                end
            end
        else
            record(value, at)
            for _, term in ipairs(node.terms) do
                if not rawequal(term.node, NULL) then
                    projection(value, term.node, at)
                end
            end
        end
    end
end

function M.validate(rows, count, compiled)
    for index = 1, count do
        local path = "$rows." .. index
        record(rows[index], path)
        projection(rows[index], compiled.node, path)
    end
end

local function compare(actual, operator, expected)
    if operator == "eq" then
        return actual == expected
    end
    if operator == "ne" then
        return actual ~= expected
    end
    if operator == "is_null" then
        return rawequal(actual, NULL) == expected
    end
    if operator == "one_of" or operator == "none_of" then
        local found = false
        for _, value in ipairs(expected) do
            if actual == value then
                found = true
                break
            end
        end
        if operator == "one_of" then
            return found
        end
        return not found
    end
    if rawequal(actual, NULL) then
        return false
    end
    if operator == "lt" then
        return actual < expected
    end
    if operator == "lte" then
        return actual <= expected
    end
    if operator == "gt" then
        return actual > expected
    end
    if operator == "gte" then
        return actual >= expected
    end
    if operator == "contains" then
        return actual:find(expected, 1, true) ~= nil
    end
    if operator == "starts_with" then
        return actual:sub(1, #expected) == expected
    end
    if operator == "ends_with" then
        return #expected == 0 or actual:sub(-#expected) == expected
    end
end

local matches
local function relation_matches(value, term, many)
    if not many then
        local result
        if rawequal(term.node, NULL) then
            result = rawequal(value, NULL)
        else
            result = not rawequal(value, NULL) and matches(value, term.node)
        end
        if term.operator == "is_not" then
            return not result
        end
        return result
    end
    for _, child in ipairs(value) do
        local result = matches(child, term.node)
        if term.operator == "some" and result then
            return true
        end
        if term.operator == "none" and result then
            return false
        end
        if term.operator == "every" and not result then
            return false
        end
    end
    return term.operator ~= "some"
end

matches = function(row, node)
    if node.kind == "AND" then
        for _, term in ipairs(node.terms) do
            if not matches(row, term) then
                return false
            end
        end
        return true
    elseif node.kind == "OR" then
        for _, term in ipairs(node.terms) do
            if matches(row, term) then
                return true
            end
        end
        return false
    elseif node.kind == "NOT" then
        return not matches(row, node.node)
    elseif node.kind == "field" then
        for _, term in ipairs(node.terms) do
            if not compare(row[node.name], term.operator, term.value) then
                return false
            end
        end
    else
        for _, term in ipairs(node.terms) do
            if
                not relation_matches(row[node.name], term, node.definition.cardinality == "many")
            then
                return false
            end
        end
    end
    return true
end
M.matches = matches

return M
