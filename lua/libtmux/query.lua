local internal = require("libtmux._internal.query")
local wire = require("libtmux._internal.query_wire")
local M = {}
local methods = {}
local compiled_queries = setmetatable({}, { __mode = "k" })
M.NULL = internal.NULL

---Encode this Lua API's versioned JSON profile using an explicit consumer codec.
---@param schema libtmux.QuerySchema
---@param criteria libtmux.Where
---@param codec table A trusted lunajson-compatible encoder and SAX parser.
---@return string? json
---@return libtmux.QueryError? error
function M.encode_json(schema, criteria, codec)
    return wire.encode(schema, criteria, codec)
end

---Decode and validate a complete JSON query; never evaluate received code.
---@param schema libtmux.QuerySchema
---@param text string
---@param codec table A trusted lunajson-compatible encoder and SAX parser.
---@return libtmux.Where? criteria
---@return libtmux.QueryError? error
function M.decode_json(schema, text, codec)
    return wire.decode(schema, text, codec)
end

---Validate and copy untrusted data; errors are returned rather than raised.
---@param schema unknown Expected libtmux.QuerySchema data.
---@param criteria unknown Expected libtmux.Where data.
---@return libtmux.CompiledQuery? compiled
---@return libtmux.QueryError? error
function M.compile(schema, criteria)
    local ok, compiled = pcall(internal.compile, schema, criteria)
    if not ok then
        return nil, compiled
    end
    local handle = {}
    compiled_queries[handle] = compiled
    return handle
end
local selection_mt = { __index = methods, __metatable = "libtmux.Selection" }
local selections = setmetatable({}, { __mode = "k" })

local function source(rows, schema)
    local stored = selections[rows]
    if schema == nil then
        schema = stored
    end
    schema = internal.schema(schema)
    local count = internal.sequence(rows, "$rows", nil, stored ~= nil)
    return schema, count
end

---@generic T
---@param rows T[]
---@param schema libtmux.QuerySchema
---@return libtmux.Selection<T>
local function selection(rows, schema)
    selections[rows] = schema
    return setmetatable(rows, selection_mt)
end

---@generic T
---@param rows T[]|libtmux.Selection<T>
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return libtmux.Selection<T>
function M.select(rows, schema)
    local count
    schema, count = source(rows, schema)
    local result = {}
    for index = 1, count do
        result[index] = rows[index]
    end
    return selection(result, schema)
end

---Run a trusted local predicate; predicate errors propagate unchanged.
---@generic T
---@param rows T[]|libtmux.Selection<T>
---@param predicate fun(row: T, index: integer): unknown
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return libtmux.Selection<T>
function M.filter(rows, predicate, schema)
    local count
    schema, count = source(rows, schema)
    if type(predicate) ~= "function" then
        internal.fail("invalid_predicate", "filter requires a function", "$predicate")
    end
    local result = {}
    for index = 1, count do
        if predicate(rows[index], index) then
            result[#result + 1] = rows[index]
        end
    end
    return selection(result, schema)
end

---Validate the entire grammar and required data before selecting records.
---@generic T
---@param rows T[]|libtmux.Selection<T>
---@param criteria libtmux.Where|libtmux.CompiledQuery
---@param schema? libtmux.QuerySchema Required for ordinary sequences with uncompiled criteria.
---@return libtmux.Selection<T>
function M.where(rows, criteria, schema)
    local compiled = compiled_queries[criteria]
    if compiled ~= nil then
        schema = schema or selections[rows] or compiled.schema
    else
        schema = schema or selections[rows]
        local handle, err = M.compile(schema, criteria)
        if handle == nil then
            error(err, 0)
        end
        compiled = compiled_queries[handle]
        schema = compiled.schema
    end
    local count
    schema, count = source(rows, schema)
    internal.check_schema(schema, compiled.node)
    internal.validate(rows, count, compiled)
    local result = {}
    for index = 1, count do
        if internal.matches(rows[index], compiled.node) then
            result[#result + 1] = rows[index]
        end
    end
    return selection(result, schema)
end

---@generic T
---@param rows T[]|libtmux.Selection<T>
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return T?
function M.first(rows, schema)
    source(rows, schema)
    return rows[1]
end

local function one(rows, schema, permit_empty)
    local _, count = source(rows, schema)
    if count == 0 and not permit_empty then
        return nil, internal.error("no_match", "no rows matched", "$rows", "one")
    elseif count > 1 then
        return nil,
            internal.error(
                "multiple_matches",
                "at least two rows matched",
                "$rows",
                permit_empty and "one_or_nil" or "one"
            )
    end
    return rows[1]
end

---@generic T
---@param rows T[]|libtmux.Selection<T>
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return T?
---@return libtmux.QueryError? error
function M.one(rows, schema)
    return one(rows, schema, false)
end
---@generic T
---@param rows T[]|libtmux.Selection<T>
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return T?
---@return libtmux.QueryError? error
function M.one_or_nil(rows, schema)
    return one(rows, schema, true)
end
---@param rows table[]|libtmux.Selection<table>
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return boolean
function M.exists(rows, schema)
    local _, count = source(rows, schema)
    return count > 0
end
---@param rows table[]|libtmux.Selection<table>
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return integer
function M.count(rows, schema)
    local _, count = source(rows, schema)
    return count
end

---@generic T
---@param rows T[]|libtmux.Selection<T>
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return fun(): T?
function M.iter(rows, schema)
    local _, count = source(rows, schema)
    local index = 0
    return function()
        index = index + 1
        if index <= count then
            return rows[index]
        end
    end
end

---@generic T
---@param rows T[]|libtmux.Selection<T>
---@param schema? libtmux.QuerySchema Required for ordinary sequences.
---@return T[]
function M.to_table(rows, schema)
    local _, count = source(rows, schema)
    local result = {}
    for index = 1, count do
        result[index] = rows[index]
    end
    return result
end

for _, name in ipairs({
    "where",
    "filter",
    "first",
    "one",
    "one_or_nil",
    "exists",
    "count",
    "iter",
    "to_table",
}) do
    methods[name] = M[name]
end

---@class libtmux.QueryError
---@field code string Stable machine-readable error code.
---@field operation string
---@field message string
---@field path string Criteria, schema, or data path.

---@class libtmux.Null Explicit loaded absence; nil means an unloaded field.

---@class libtmux.QueryField
---@field type "string"|"number"|"boolean"
---@field nullable? boolean Defaults to false.
---@field supported? boolean Defaults to true.

---@class libtmux.QueryRelation
---@field cardinality "one"|"many"
---@field schema libtmux.QuerySchema
---@field nullable? boolean Only to-one relations can be nullable.
---@field supported? boolean Defaults to true.

---@class libtmux.QuerySchema
---@field name? string
---@field fields? table<string, libtmux.QueryField> Supply fields or relations.
---@field relations? table<string, libtmux.QueryRelation>

---@alias libtmux.QueryScalar string|number|boolean|libtmux.Null

---@class libtmux.FieldCriteria
---@field eq? libtmux.QueryScalar
---@field ne? libtmux.QueryScalar
---@field one_of? libtmux.QueryScalar[]
---@field none_of? libtmux.QueryScalar[]
---@field lt? number
---@field lte? number
---@field gt? number
---@field gte? number
---@field contains? string
---@field starts_with? string
---@field ends_with? string
---@field is_null? boolean

---@class libtmux.RelationCriteria
---@field some? libtmux.Where
---@field every? libtmux.Where
---@field none? libtmux.Where
---@field is? libtmux.Where|libtmux.Null
---@field is_not? libtmux.Where|libtmux.Null

---@alias libtmux.WhereValue libtmux.QueryScalar
---| libtmux.FieldCriteria
---| libtmux.RelationCriteria
---| libtmux.Where
---| libtmux.Where[]

---@class libtmux.Where: table<string, libtmux.WhereValue>
---@field AND? libtmux.Where[]
---@field OR? libtmux.Where[]
---@field NOT? libtmux.Where

---@class libtmux.CompiledQuery Opaque compiled criteria handle.

---@alias libtmux.QueryInput libtmux.Where|libtmux.CompiledQuery
---@alias libtmux.Predicate<T> fun(row: T, index: integer): unknown

---@class libtmux.Selection<T>: { [integer]: T }
---@field where fun(self:libtmux.Selection<T>, criteria:libtmux.QueryInput):libtmux.Selection<T>
---@field filter fun(self:libtmux.Selection<T>, predicate:libtmux.Predicate<T>):libtmux.Selection<T>
---@field first fun(self: libtmux.Selection<T>): T?
---@field one fun(self: libtmux.Selection<T>): T?, libtmux.QueryError?
---@field one_or_nil fun(self: libtmux.Selection<T>): T?, libtmux.QueryError?
---@field exists fun(self: libtmux.Selection<T>): boolean
---@field count fun(self: libtmux.Selection<T>): integer
---@field iter fun(self: libtmux.Selection<T>): fun(): T?
---@field to_table fun(self: libtmux.Selection<T>): T[]

return M
