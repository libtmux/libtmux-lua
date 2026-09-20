local adapter = require("libtmux.runtime.luv")
local planner = require("libtmux._internal.planner")
local query = require("libtmux.query")

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

local function same(first, second)
    assert(#first == #second, "native candidates changed local match count")
    for index, row in ipairs(first) do
        assert(row == second[index], "native candidates changed record identity or order")
    end
end

local result = must(adapter.run(function(runtime)
    local server = must(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
            config_path = "/dev/null",
        })
        :await())
    local snapshot = must(server:snapshot():await())
    local version = snapshot.capabilities.version
    assert(snapshot.complete and #snapshot.panes == 3 and #snapshot.raw.panes == 6)
    local first = snapshot.panes[1]
    local cases = {}
    for _, name in ipairs({
        "id",
        "window_id",
        "active",
        "dead",
        "synchronized",
        "index",
        "width",
        "height",
        "left",
        "top",
        "pid",
        "mode_count",
    }) do
        cases[#cases + 1] = { where = { [name] = first[name] }, exact = true }
    end
    cases[#cases + 1] = { where = { active = false, width = first.width }, exact = true }
    cases[#cases + 1] = { where = {}, exact = true }
    for _, where in ipairs({
        { title = "#{pane_id}" },
        { OR = { { active = true }, { title = "needle" } } },
        { NOT = { active = true, title = "needle" } },
        { active = false, title = "needle" },
        { dead_status = query.NULL },
        { width = 1.5 },
        { active = true, window = { is = { panes = { every = { active = true } } } } },
    }) do
        cases[#cases + 1] = { where = where, exact = false }
    end
    local commands, automatic_plans, candidate_ids = {}, {}, {}
    for index, case in ipairs(cases) do
        local automatic = must(planner.new(version, { where = case.where, pushdown = "auto" }))
        local argv = must(planner.explain(automatic)).source.argv
        -- These fixture records contain only a fixed case index and native numeric pane ID.
        argv[#argv + 1], argv[#argv + 2] = "-F", tostring(index) .. ":#{pane_id}"
        commands[index], automatic_plans[index], candidate_ids[index] = argv, automatic, {}
    end
    local output = must(server:group(commands):await())
    assert(output.exit_code == 0 and output.signal == 0, output.stderr)
    assert(output.stdout == "" or output.stdout:sub(-1) == "\n")
    for line in output.stdout:gmatch("([^\n]+)\n") do
        local index, id = line:match("^(%d+):(%%%d+)$")
        local ids = index and candidate_ids[tonumber(index)]
        assert(ids and id, "invalid candidate fixture record")
        ids[id] = true
    end
    for index, case in ipairs(cases) do
        local local_plan = must(planner.new(version, { where = case.where, pushdown = "never" }))
        local expected = must(planner.apply(local_plan, snapshot.panes))
        same(expected, snapshot.panes:where(case.where))
        local automatic, selected = automatic_plans[index], {}
        for _, row in ipairs(snapshot.panes) do
            if candidate_ids[index][row.id] then
                selected[#selected + 1] = row
            end
        end
        same(expected, must(planner.apply(automatic, selected)))
        local exact, err = planner.new(version, { where = case.where, pushdown = "require" })
        if case.exact then
            assert(exact, tostring(err))
            assert(planner.explain(exact).filter == planner.explain(automatic).filter)
            same(expected, must(planner.apply(exact, selected)))
        else
            assert(exact == nil and assert(err).code == "unsupported_pushdown")
        end
    end
    local collections = {
        session = "sessions",
        window = "windows",
        pane = "panes",
        window_link = "window_links",
        client = "clients",
        buffer = "buffers",
    }
    for kind, name in pairs(collections) do
        local local_plan = must(planner.new(version, { kind = kind, pushdown = "never" }))
        local automatic = must(planner.new(version, { kind = kind, pushdown = "auto" }))
        same(must(planner.apply(local_plan, snapshot[name])), snapshot[name])
        same(must(planner.apply(automatic, snapshot[name])), snapshot[name])
    end
    must(server:close():await())
    return "live query planner PASS " .. version
end))
print(result)
