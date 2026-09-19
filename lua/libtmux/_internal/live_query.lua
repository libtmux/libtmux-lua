local errors = require("libtmux._internal.error")
local planner = require("libtmux._internal.planner")
local metadata = require("libtmux._internal.metadata")
local process = require("libtmux._internal.process")
local M = {}
local collections = {
    session = "sessions",
    window = "windows",
    pane = "panes",
    window_link = "window_links",
    client = "clients",
    buffer = "buffers",
}

local function failure(code, message, cause, effect)
    return errors.new(
        code,
        message,
        { operation = "query", effect = effect or "not_sent", cause = cause }
    )
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

local function cost(value)
    if type(value) == "string" then
        return #value
    end
    if type(value) ~= "table" then
        return 8
    end
    local bytes = 8
    for key, item in pairs(value) do
        bytes = bytes + cost(key) + cost(item)
    end
    return bytes
end

local function prepare(state, options, forced_kind)
    options = options == nil and {} or options
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return nil, failure("invalid_options", "query options must be a plain record")
    end
    for key in next, options do
        if
            key ~= "kind"
            and key ~= "where"
            and key ~= "pushdown"
            and key ~= "native_filter"
            and key ~= "snapshot"
        then
            return nil, failure("invalid_options", "unknown live query option")
        end
    end
    if forced_kind and options.kind ~= nil and options.kind ~= forced_kind then
        return nil, failure("invalid_options", "query kind conflicts with the selected method")
    end
    local kind = forced_kind or (options.kind == nil and "pane" or options.kind)
    local native = options.native_filter
    if native ~= nil and (options.where ~= nil or options.pushdown ~= nil) then
        return nil,
            failure("invalid_options", "native_filter cannot be combined with where or pushdown")
    end
    if
        native ~= nil
        and (
            kind ~= "pane"
            or type(native) ~= "string"
            or #native == 0
            or #native > 16384
            or native:find("\000", 1, true)
        )
    then
        return nil,
            failure("invalid_options", "native_filter requires a bounded NUL-free pane format")
    end
    local plan, err = planner.new(
        state.version,
        { kind = kind, where = options.where, pushdown = options.pushdown }
    )
    if not plan then
        assert(err)
        return nil, failure(err.code, err.message, err)
    end
    local explained = assert(planner.explain(plan))
    if native ~= nil then
        explained.filter, explained.native_filter, explained.exact = native, true, false
        explained.source.argv = { "list-panes", "-a", "-f", native }
        explained.residual =
            { { path = "$", reason = "expert_native_filter_has_no_local_equivalent" } }
    end
    local configured
    configured, err = state.prepare_capture(options.snapshot)
    if not configured then
        return nil, err
    end
    local capture = {
        strict = configured.strict,
        timeout = configured.timeout,
        max_rows = configured.max_rows,
        max_bytes = configured.max_bytes,
        fields = {},
    }
    explained.projections, explained.commands = {}, {}
    for entity, name in pairs(collections) do
        local names, seen = copy(configured.effective[entity]), {}
        for _, field in ipairs(names) do
            seen[field] = true
        end
        for _, field in ipairs(explained.fields[name] or {}) do
            if not seen[field] then
                names[#names + 1], seen[field] = field, true
            end
        end
        capture.fields[name], explained.projections[entity] = names, copy(names)
    end
    local projection = assert(metadata.projection("pane", state.version, { "id" }))
    explained.commands = state.capture_commands(assert(state.prepare_capture(capture)))
    if explained.filter then
        local argv = explained.source.argv
        argv[#argv + 1], argv[#argv + 2] = "-F", assert(metadata.format(projection))
        explained.commands[#explained.commands + 1] = { role = "candidates", argv = copy(argv) }
    end
    explained.consistency =
        { atomic = false, strict = capture.strict, verification_passes = capture.strict and 1 or 0 }
    explained.empty_server = "only sessions and buffers are listed on a sessionless server"
    return {
        plan = plan,
        explained = explained,
        capture = capture,
        projection = projection,
        kind = kind,
    }
end

function M.run(state, options, explain_only, forced_kind)
    local prepared, validation_error = prepare(state, options, forced_kind)
    local request = state.runtime:_operation(function(_, operation)
        if state.closed then
            return nil, failure("closed", "server handle is closed")
        end
        if not prepared then
            return nil, validation_error
        end
        local generation, err = state.bound:generation()
        if not generation then
            return nil, err
        end
        if explain_only then
            return prepared.explained
        end
        local started = state.runtime._driver.now()
        operation:_set_effect("unknown")
        local captured = state.capture(prepared.capture)
        local snapshot
        snapshot, err = captured:await()
        local retained, cause = operation:_retain(captured._cost)
        if not retained then
            return nil,
                failure(
                    "queue_full",
                    "query snapshot exceeds retained byte capacity",
                    cause,
                    err and err.effect or "completed"
                )
        end
        if not snapshot then
            return nil, err
        end
        local candidates
        if prepared.explained.filter and #snapshot.sessions > 0 then
            local result
            result, err = state.bound
                :execute(prepared.explained.source.argv, {
                    timeout = prepared.capture.timeout,
                    max_output_bytes = prepared.capture.max_bytes,
                })
                :await()
            result, err = process.retain_output(operation, result, err, "query")
            if not result then
                return nil, err
            end
            local rows
            rows, err = metadata.decode(result.stdout, prepared.projection, {
                max_rows = prepared.capture.max_rows,
                max_bytes = prepared.capture.max_bytes,
            })
            if not rows then
                return nil,
                    failure("invalid_result", "query candidates are malformed", err, "completed")
            end
            candidates = {}
            for _, row in ipairs(rows) do
                if #row.id > 32 or not row.id:match("^%%%d+$") then
                    return nil,
                        failure(
                            "invalid_result",
                            "query candidate has an invalid pane ID",
                            nil,
                            "completed"
                        )
                end
                candidates[row.id] = true
            end
        end
        local rows
        -- Validate all loaded data before pruning; quantified relations retain the full graph.
        rows, err = planner.apply(prepared.plan, snapshot[collections[prepared.kind]])
        if not rows then
            assert(err)
            return nil, failure(err.code, err.message, err, "completed")
        end
        local races, complete = copy(snapshot.races), snapshot.complete
        if candidates then
            local known = {}
            for _, row in ipairs(snapshot.panes) do
                known[row.id] = row
            end
            for id in pairs(candidates) do
                if not known[id] then
                    complete = false
                    races[#races + 1] = { code = "candidate_missing", id = id }
                elseif not prepared.explained.native_filter then
                    for _, term in ipairs(prepared.explained.pushed) do
                        if known[id][term.field] ~= term.value then
                            complete = false
                            races[#races + 1] = { code = "candidate_changed", id = id }
                            break
                        end
                    end
                end
            end
            if not prepared.explained.native_filter then
                for _, row in ipairs(rows) do
                    if not candidates[row.id] then
                        complete = false
                        races[#races + 1] = { code = "candidate_changed", id = row.id }
                    end
                end
            end
            rows = rows:filter(function(row)
                return candidates[row.id]
            end)
        end
        if state.closed then
            return nil, failure("closed", "server handle closed during query", nil, "completed")
        end
        local current
        current, err = state.bound:generation()
        if not current then
            return nil, err
        end
        if not rawequal(current, generation) then
            return nil,
                failure(
                    "stale_generation",
                    "server generation changed during query",
                    nil,
                    "completed"
                )
        end
        return {
            rows = rows,
            snapshot = snapshot,
            plan = prepared.explained,
            acquisition = { started = started, finished = state.runtime._driver.now() },
            complete = complete,
            races = races,
        }
    end, { operation = explain_only and "query.explain" or "query", effect = "not_sent" })
    if prepared and not request:is_settled() then
        local bytes = assert(planner.cost(prepared.plan))
            + cost(prepared.explained)
            + cost(prepared.capture)
        local retained, err = request:_retain(bytes)
        if not retained then
            request:cancel(failure("queue_full", "query input exceeds runtime byte capacity", err))
        end
    end
    return request
end

---@class libtmux.LiveQueryOptions
---@field kind? "session"|"window"|"pane"|"window_link"|"client"|"buffer"
---@field where? libtmux.Where
---@field pushdown? "never"|"auto"|"require"
---@field native_filter? string Expert pane format; excludes where and pushdown.
---@field snapshot? libtmux.SnapshotOptions Full graph acquisition; required query fields are added.

---@class libtmux.LiveQueryPlan
---@field kind string
---@field version string
---@field pushdown string
---@field exact boolean Whether the full predicate has a native translation.
---@field filter? string
---@field native_filter? boolean
---@field source {argv:string[]}
---@field commands {role:string,kind?:string,argv:string[]}[] Ordered phases; see empty_server.
---@field projections table<string,string[]>
---@field fields table<string,string[]>
---@field hydration string[]
---@field pushed table[]
---@field residual {path:string,reason:string}[]
---@field consistency {atomic:boolean,strict:boolean,verification_passes:integer}
---@field empty_server string

---@class libtmux.LiveQueryResult<T>
---@field rows libtmux.Selection<T>
---@field snapshot libtmux.Snapshot Complete captured relationship universe.
---@field plan libtmux.LiveQueryPlan
---@field complete boolean False for known races; true does not imply atomic acquisition.
---@field races table[]
---@field acquisition {started:number,finished:number}

return M
