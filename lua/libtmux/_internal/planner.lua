local errors = require("libtmux._internal.error")
local fields = require("libtmux._internal.fields")
local graph = require("libtmux._internal.graph")
local internal = require("libtmux._internal.query")
local query = require("libtmux.query")
local M = {}
---@type table<table,{compiled:table,explained:table,cost:number}>
local plans = setmetatable({}, { __mode = "k" })
local collections = {
    session = "sessions",
    window = "windows",
    pane = "panes",
    window_link = "window_links",
    client = "clients",
    buffer = "buffers",
}
local commands = {
    session = { "list-sessions" },
    window = { "list-windows", "-a" },
    pane = { "list-panes", "-a" },
    window_link = { "list-windows", "-a" },
    client = { "list-clients" },
    buffer = { "list-buffers" },
}
local pane_fields = {
    id = "%",
    window_id = "@",
    active = "boolean",
    dead = "boolean",
    synchronized = "boolean",
    index = "number",
    width = "number",
    height = "number",
    left = "number",
    top = "number",
    pid = "number",
    mode_count = "number",
}

local function fail(code, message, details)
    details = details or {}
    details.operation, details.effect = "query", "not_sent"
    error(errors.new(code, message, details), 0)
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        result[key] = copy(child)
    end
    return result
end

local function sorted_keys(values)
    local result = {}
    for key in pairs(values) do
        result[#result + 1] = key
    end
    table.sort(result)
    return result
end

local function retained_cost(value)
    local pending, seen, bytes, count = { value }, {}, 0, 0
    while #pending > 0 do
        local item = pending[#pending]
        pending[#pending] = nil
        count, bytes = count + 1, bytes + 8
        if count > 131072 then
            fail("query_limit", "compiled query exceeds its retained-value limit")
        end
        if type(item) == "string" then
            bytes = bytes + #item
        elseif type(item) == "table" and not seen[item] then
            seen[item], bytes = true, bytes + 32
            for key, child in next, item do
                pending[#pending + 1] = key
                pending[#pending + 1] = child
            end
        end
    end
    -- This bounds retained scalar data and table slots, not interpreter heap overhead.
    return bytes
end

local function requirements(node, schema, prefix, needed, hydration)
    if node.kind == "AND" or node.kind == "OR" then
        for _, child in ipairs(node.terms) do
            requirements(child, schema, prefix, needed, hydration)
        end
    elseif node.kind == "NOT" then
        requirements(node.node, schema, prefix, needed, hydration)
    elseif node.kind == "field" then
        local name = collections[schema.name]
        needed[name] = needed[name] or {}
        needed[name][node.name] = true
    else
        local path = prefix == "" and node.name or prefix .. "." .. node.name
        hydration[path] = true
        for _, term in ipairs(node.terms) do
            if not rawequal(term.node, internal.NULL) then
                requirements(term.node, node.definition.schema, path, needed, hydration)
            end
        end
    end
end

local function operand(node, term)
    local kind, value = pane_fields[node.name], term.value
    if term.operator ~= "eq" then
        return nil, "operator_remains_local"
    elseif node.definition.nullable then
        return nil, "nullable_field_remains_local"
    elseif kind == "boolean" then
        return value and "1" or "0"
    elseif kind == "number" then
        if value % 1 ~= 0 or value < -9007199254740991 or value > 9007199254740991 then
            return nil, "number_has_no_exact_native_encoding"
        end
        return value == 0 and "0" or string.format("%.0f", value)
    elseif kind == "%" or kind == "@" then
        local pattern = kind == "%" and "^%%[0-9]+$" or "^@[0-9]+$"
        if value:match(pattern) then
            return value
        end
        return nil, "id_has_no_safe_native_encoding"
    end
    return nil, "field_remains_local"
end

local function translate(node, catalog, candidates, residual)
    if node.kind == "AND" then
        for _, child in ipairs(node.terms) do
            translate(child, catalog, candidates, residual)
        end
    elseif node.kind == "field" then
        for _, term in ipairs(node.terms) do
            local value, reason = operand(node, term)
            local path = node.path .. "." .. term.operator
            if value then
                candidates[#candidates + 1] = {
                    path = path,
                    field = node.name,
                    operator = "eq",
                    value = term.value,
                    expression = "#{==:#{" .. catalog[node.name].format .. "}," .. value .. "}",
                }
            else
                residual[#residual + 1] = { path = path, reason = reason }
            end
        end
    else
        -- A necessary conjunct may prune candidates; OR/NOT/relation children may not.
        residual[#residual + 1] = {
            path = node.path or "$",
            reason = node.kind == "relation" and "relation_remains_local"
                or "boolean_subtree_remains_local",
        }
    end
end

local function balanced(terms, first, last)
    if first == last then
        return terms[first].expression
    end
    local middle = math.floor((first + last) / 2)
    return "#{&&:"
        .. balanced(terms, first, middle)
        .. ","
        .. balanced(terms, middle + 1, last)
        .. "}"
end

local function prepare(version, options)
    options = options == nil and {} or options
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        fail("invalid_options", "query options must be a plain record")
    end
    for key in next, options do
        if key ~= "kind" and key ~= "where" and key ~= "pushdown" then
            fail("invalid_options", "unknown query option")
        end
    end
    local kind = options.kind == nil and "pane" or options.kind
    local mode = options.pushdown == nil and "auto" or options.pushdown
    if not collections[kind] then
        fail("invalid_entity", "query needs a snapshot entity kind")
    elseif mode ~= "auto" and mode ~= "never" and mode ~= "require" then
        fail("invalid_options", "pushdown must be never, auto, or require")
    end
    local schema = graph.schemas(version)[kind]
    local compiled = internal.compile(schema, options.where == nil and {} or options.where)
    local needed, hydration = {}, {}
    requirements(compiled.node, compiled.schema, "", needed, hydration)
    for name, names in pairs(needed) do
        needed[name] = sorted_keys(names)
    end
    local explained = {
        version = version,
        kind = kind,
        pushdown = mode,
        source = { argv = copy(commands[kind]) },
        fields = needed,
        hydration = sorted_keys(hydration),
        pushed = {},
        residual = {},
        exact = false,
    }
    if mode == "never" or kind ~= "pane" then
        explained.residual[1] = {
            path = "$",
            reason = mode == "never" and "pushdown_disabled" or "native_kind_unavailable",
        }
    else
        local candidates = {}
        translate(compiled.node, assert(fields.catalog(kind)), candidates, explained.residual)
        table.sort(candidates, function(first, second)
            if first.path ~= second.path then
                return first.path < second.path
            end
            return first.expression < second.expression
        end)
        local bytes = 0
        for _, candidate in ipairs(candidates) do
            local size = #candidate.expression + (#explained.pushed == 0 and 0 or 7)
            if #explained.pushed >= 256 or bytes + size > 16384 then
                explained.residual[#explained.residual + 1] = {
                    path = candidate.path,
                    reason = "native_expression_limit",
                }
            else
                explained.pushed[#explained.pushed + 1] = candidate
                bytes = bytes + size
            end
        end
        if #explained.pushed > 0 then
            -- tmux limits format recursion to 100; a left fold can silently lose matches.
            explained.filter = balanced(explained.pushed, 1, #explained.pushed)
            local argv = explained.source.argv
            argv[#argv + 1], argv[#argv + 2] = "-f", explained.filter
        end
        explained.exact = #explained.residual == 0
    end
    table.sort(explained.residual, function(first, second)
        if first.path ~= second.path then
            return first.path < second.path
        end
        return first.reason < second.reason
    end)
    if mode == "require" and not explained.exact then
        fail("unsupported_pushdown", "query cannot be translated completely for this source", {
            kind = kind,
            version = version,
            reasons = copy(explained.residual),
        })
    end
    local plan = {}
    local stored = { compiled = compiled, explained = explained }
    stored.cost = retained_cost(stored)
    plans[plan] = stored
    return plan
end

---@return table? plan
---@return libtmux.Error|libtmux.QueryError? error
function M.new(version, options)
    local ok, result = pcall(prepare, version, options)
    if not ok then
        return nil, result
    end
    return result
end

---@return {compiled:table,explained:table,cost:number}
local function state(plan)
    local stored
    if type(plan) == "table" then
        stored = plans[plan]
    end
    if not stored then
        fail("invalid_plan", "query plan is not recognized")
    end
    return assert(stored)
end

---@return table? explanation
---@return libtmux.Error? error
function M.explain(plan)
    local ok, stored = pcall(state, plan)
    if not ok then
        return nil, stored
    end
    return copy(stored.explained)
end

---@return number? bytes
---@return libtmux.Error? error
function M.cost(plan)
    local ok, stored = pcall(state, plan)
    if not ok then
        return nil, stored
    end
    return stored.cost
end

local function apply(plan, rows)
    local compiled = state(plan).compiled
    local copied = query.to_table(rows, compiled.schema)
    internal.check_schema(compiled.schema, compiled.node)
    internal.validate(copied, #copied, compiled)
    local result = {}
    for _, row in ipairs(copied) do
        if internal.matches(row, compiled.node) then
            result[#result + 1] = row
        end
    end
    return query.select(result, compiled.schema)
end

---@return libtmux.Selection<table<string,any>>? rows
---@return libtmux.Error|libtmux.QueryError? error
function M.apply(plan, rows)
    local ok, result = pcall(apply, plan, rows)
    if not ok then
        return nil, result
    end
    return result
end

return M
