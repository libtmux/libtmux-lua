local errors = require("libtmux._internal.error")
local fields = require("libtmux._internal.fields")
local identity = require("libtmux._internal.identity")
local query = require("libtmux.query")
local M = {}
local snapshots = setmetatable({}, { __mode = "k" })
local collections = {
    { "session", "sessions" },
    { "window", "windows" },
    { "pane", "panes" },
    { "window_link", "window_links" },
    { "client", "clients" },
    { "buffer", "buffers" },
}

local function fail(code, message, details)
    error(errors.new(code, message, details), 0)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

local function sequence(value, maximum)
    if not plain(value) then
        fail("invalid_snapshot", "snapshot rows must be plain dense sequences")
    end
    local count = 0
    for key in next, value do
        count = count + 1
        if count > maximum then
            fail("snapshot_limit", "snapshot exceeds its row limit")
        end
        if not integer(key, 1, maximum) then
            fail("invalid_snapshot", "snapshot sequence keys must be bounded positive integers")
        end
    end
    for index = 1, count do
        if rawget(value, index) == nil then
            fail("invalid_snapshot", "snapshot sequence contains a hole")
        end
    end
    return count
end

function M.schemas(version)
    local result = {}
    for _, pair in ipairs(collections) do
        local schema, err = fields.schema(pair[1], version)
        if not schema then
            error(err, 0)
        end
        result[pair[1]] = schema
        schema.relations = {}
    end
    local function relation(from, name, to, cardinality, nullable)
        result[from].relations[name] = {
            schema = result[to],
            cardinality = cardinality,
            nullable = nullable or false,
        }
    end
    relation("session", "window_links", "window_link", "many")
    relation("window", "window_links", "window_link", "many")
    relation("window", "panes", "pane", "many")
    relation("window_link", "session", "session", "one")
    relation("window_link", "window", "window", "one")
    relation("pane", "window", "window", "one")
    relation("client", "session", "session", "one", true)
    return result
end

local function reference(generation, kind, row)
    local ref = { generation = generation, kind = kind }
    local key
    if kind == "window_link" then
        ref.session_id, ref.window_id, ref.index = row.session_id, row.window_id, row.index
        key = tostring(row.session_id)
            .. ":"
            .. tostring(row.index)
            .. ":"
            .. tostring(row.window_id)
    elseif kind == "client" then
        ref.name, ref.tty = row.name, row.tty
        key = tostring(row.name) .. "\000" .. tostring(row.tty)
    elseif kind == "buffer" then
        ref.name, key = row.name, row.name
    else
        ref.id, key = row.id, row.id
    end
    local handle, err = identity.bind(generation, ref)
    if not handle then
        fail("invalid_snapshot", "snapshot row has an invalid entity identity", { cause = err })
    end
    return key, handle, ref
end

local function same_record(first, second)
    for key, value in pairs(first) do
        if key ~= "ref" and second[key] ~= value then
            return false
        end
    end
    for key, value in pairs(second) do
        if key ~= "ref" and first[key] ~= value then
            return false
        end
    end
    return true
end

local function assemble(generation, listings, info)
    local evidence, err = identity.evidence(generation)
    if not evidence then
        error(err, 0)
    end
    if not plain(listings) or not plain(info) then
        fail("invalid_snapshot", "snapshot needs captured listings and acquisition metadata")
    end
    local allowed =
        { started = true, finished = true, max_rows = true, max_bytes = true, strict = true }
    for key in next, info do
        if not allowed[key] then
            fail("invalid_snapshot", "unknown snapshot acquisition option")
        end
    end
    local max_rows = info.max_rows == nil and 65536 or info.max_rows
    local max_bytes = info.max_bytes == nil and 16 * 1024 * 1024 or info.max_bytes
    if
        not integer(max_rows, 1, 65536)
        or not integer(max_bytes, 1, 2147483647)
        or type(info.started) ~= "number"
        or type(info.finished) ~= "number"
        or info.started < 0
        or info.finished < info.started
        or info.finished == math.huge
        or info.started ~= info.started
        or info.finished ~= info.finished
        or (info.strict ~= nil and type(info.strict) ~= "boolean")
    then
        fail("invalid_snapshot", "snapshot acquisition interval or limits are invalid")
    end
    local known = {}
    for _, pair in ipairs(collections) do
        known[pair[2]] = true
    end
    for name in next, listings do
        if not known[name] then
            fail("invalid_snapshot", "unknown snapshot collection")
        end
    end
    local schema = M.schemas(evidence.version)
    local result = {
        raw = {},
        races = {},
        complete = true,
        acquisition = { started = info.started, finished = info.finished },
        projections = {},
    }
    local state = { generation = generation, handles = {}, indexes = {} }
    local captured = {}
    local rows_seen, bytes_seen = 0, 0
    local function race(code, kind, key, relation)
        result.complete = false
        result.races[#result.races + 1] =
            { code = code, kind = kind, key = key, relation = relation }
    end
    for _, pair in ipairs(collections) do
        local kind, name = pair[1], pair[2]
        local rows = listings[name]
        local count = sequence(rows, max_rows)
        rows_seen = rows_seen + count
        if rows_seen > max_rows then
            fail("snapshot_limit", "snapshot exceeds its total row limit")
        end
        local index, canonical, raw, projection = {}, {}, {}, {}
        state.indexes[kind] = index
        for position = 1, count do
            local input, record = rows[position], {}
            if not plain(input) then
                fail("invalid_snapshot", "snapshot records must be plain scalar tables")
            end
            for key, value in next, input do
                local field = schema[kind].fields[key]
                local absent = rawequal(value, query.NULL)
                if
                    not field
                    or field.supported == false
                    or (absent and not field.nullable)
                    or (not absent and type(value) ~= field.type)
                    or (
                        type(value) == "number"
                        and not integer(value, -9007199254740991, 9007199254740991)
                    )
                then
                    fail("invalid_snapshot", "snapshot field does not match its schema", {
                        kind = kind,
                        field = key,
                        row = position,
                    })
                end
                bytes_seen = bytes_seen + (type(value) == "string" and #value or 8) + #key
                if bytes_seen > max_bytes then
                    fail("snapshot_limit", "snapshot exceeds its retained byte limit")
                end
                record[key], projection[key] = value, true
            end
            local key, handle, ref = reference(generation, kind, record)
            record.ref, state.handles[record] = ref, handle
            raw[#raw + 1] = record
            if index[key] and not same_record(index[key], record) then
                race("conflicting_entity", kind, key)
            end
            if not index[key] or kind == "window_link" then
                canonical[#canonical + 1] = record
                index[key] = index[key] or record
            end
        end
        result[name] = canonical
        captured[name] = canonical
        result.raw[name] = query.select(raw, fields.schema(kind, evidence.version))
        local names = {}
        for field_name in pairs(projection) do
            names[#names + 1] = field_name
        end
        table.sort(names)
        result.projections[kind] = names
    end
    local by = state.indexes
    local session_names, ambiguous_names, link_positions = {}, {}, {}
    for _, session in ipairs(result.sessions) do
        session.window_links = {}
        if session.name then
            if session_names[session.name] or ambiguous_names[session.name] then
                session_names[session.name] = nil
                ambiguous_names[session.name] = true
                race("ambiguous_identity", "session", session.name)
            else
                session_names[session.name] = session
            end
        end
    end
    for _, window in ipairs(result.windows) do
        window.panes, window.window_links = {}, {}
    end
    for _, link in ipairs(result.window_links) do
        local session, window = by.session[link.session_id], by.window[link.window_id]
        link.session, link.window = session, window
        local position = link.session_id .. ":" .. link.index
        if link_positions[position] and link_positions[position] ~= link.window_id then
            race("conflicting_link", "window_link", position)
        end
        link_positions[position] = link.window_id
        if session then
            session.window_links[#session.window_links + 1] = link
        else
            race("missing_relation", "window_link", position, "session")
        end
        if window then
            window.window_links[#window.window_links + 1] = link
        else
            race("missing_relation", "window_link", position, "window")
        end
    end
    for _, pane in ipairs(result.panes) do
        local window = by.window[pane.window_id]
        pane.window = window
        if window then
            window.panes[#window.panes + 1] = pane
        else
            race("missing_relation", "pane", pane.id, "window")
        end
    end
    for _, client in ipairs(result.clients) do
        if rawequal(client.session_name, query.NULL) then
            client.session = query.NULL
        elseif client.session_name ~= nil then
            client.session = session_names[client.session_name]
            if ambiguous_names[client.session_name] then
                race("ambiguous_relation", "client", client.name, "session")
            elseif not client.session then
                race("missing_relation", "client", client.name, "session")
            end
        end
    end
    for _, pair in ipairs(collections) do
        result[pair[2]] = query.select(captured[pair[2]], schema[pair[1]])
    end
    snapshots[result] = state
    if info.strict and not result.complete then
        fail("inconsistent_snapshot", "captured rows do not describe a consistent topology", {
            partial = result,
        })
    end
    return result
end

function M.build(generation, listings, info)
    local ok, result = pcall(assemble, generation, listings, info)
    if not ok then
        return nil, errors.wrap(result, "invalid_snapshot")
    end
    return result
end

function M.lookup(snapshot, kind, key)
    local state = snapshots[snapshot]
    if not state or not state.indexes[kind] then
        return nil, errors.new("invalid_snapshot", "unknown snapshot or entity kind")
    end
    return state.indexes[kind][key]
end

function M.handle(snapshot, record)
    local state = snapshots[snapshot]
    local handle = state and state.handles[record]
    if not handle then
        return nil, errors.new("invalid_reference", "record does not belong to this snapshot")
    end
    local ref, err = identity.inspect(state.generation, handle)
    if not ref then
        return nil, err
    end
    return identity.bind(state.generation, ref)
end

return M
