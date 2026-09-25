local errors = require("libtmux._internal.error")
local execution = require("libtmux._internal.execution")
local identity = require("libtmux._internal.identity")
local process = require("libtmux._internal.process")
local command = require("libtmux._internal.command")
local domain = require("libtmux._internal.domain")
local M = {}
local STALE_LINK = "__libtmux_stale_link_v1__"
local versions = {
    ["3.2a"] = 2,
    ["3.3"] = 3,
    ["3.3a"] = 3,
    ["3.4"] = 4,
    ["3.5"] = 5,
    ["3.5a"] = 5,
    ["3.6"] = 6,
    ["3.6a"] = 6,
    ["3.6b"] = 6,
    ["3.7"] = 7,
    ["3.7a"] = 7,
    ["3.7b"] = 7,
    ["3.7c"] = 7,
}
local allowed = {
    rename = {},
    kill = {},
    renumber_windows = {},
    navigate_window = { activity = true },
    resize = {
        width = true,
        height = true,
        direction = true,
        amount = true,
        largest = true,
        smallest = true,
    },
    layout = { named = true, layout = true, next = true, previous = true, restore = true },
    select = {},
    link = { select = true, replace = true },
    move = { select = true, replace = true },
    swap = { select = true },
    unlink = { kill_if_last = true },
    move_to = {
        direction = true,
        size = true,
        percent = true,
        before = true,
        full_size = true,
        select = true,
        target_link = true,
    },
    break_out = { name = true, select = true },
    respawn = {
        context = true,
        kill = true,
        argv = true,
        shell = true,
        cwd = true,
        environment = true,
    },
}
local targets = {
    session = {
        rename = "rename-session",
        kill = "kill-session",
        renumber_windows = "move-window",
        navigate_window = true,
    },
    window = {
        rename = "rename-window",
        kill = "kill-window",
        resize = "resize-window",
        layout = "select-layout",
        respawn = "respawn-window",
    },
    window_link = {
        select = "select-window",
        link = "link-window",
        move = "move-window",
        swap = "swap-window",
        unlink = "unlink-window",
    },
    pane = { move_to = "join-pane", break_out = "break-pane" },
}
local layouts = {
    ["even-horizontal"] = 2,
    ["even-vertical"] = 2,
    ["main-horizontal"] = 2,
    ["main-vertical"] = 2,
    tiled = 2,
    ["main-horizontal-mirrored"] = 5,
    ["main-vertical-mirrored"] = 5,
}

local function operation(ref, kind)
    return (ref and ref.kind or "topology") .. "." .. (type(kind) == "string" and kind or "invalid")
end

local function failure(code, message, ref, kind, effect, details)
    details = details or {}
    details.operation, details.effect, details.target =
        operation(ref, kind), effect or "not_sent", ref
    return errors.new(code, message, details)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

local function current(state, owned, kind)
    if state.closed then
        return nil, failure("closed", "server handle is closed", nil, kind)
    end
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    local ref
    ref, err = identity.inspect(generation, owned)
    if not ref then
        return nil, err
    end
    if not targets[ref.kind] or not targets[ref.kind][kind] then
        return nil,
            failure("invalid_target", "operation is unavailable on this entity kind", ref, kind)
    end
    return ref
end

local function link_target(ref)
    return ref.session_id .. ":" .. string.format("%.0f", ref.index)
end

local function program(argv)
    -- Escape expansion bytes while keeping nested guards within tmux's message limit.
    local value, err = command.prepare_program({ commands = { argv } }, true)
    if not value then
        error(err, 0)
    end
    return value
end

local function guard(ref, argv, pane_id)
    local target = link_target(ref)
    local condition = "#{&&:#{==:#{session_id},"
        .. ref.session_id
        .. "},#{&&:#{==:#{window_index},"
        .. string.format("%.0f", ref.index)
        .. "},#{==:#{window_id},"
        .. ref.window_id
        .. "}}}"
    local rejected = program({ "display-message", "-p", STALE_LINK })
    if pane_id then
        -- A stale compound target can fail resolution before if-shell runs.
        -- Check the link and global pane separately before the compound mutation.
        argv = {
            "if-shell",
            "-F",
            "-t",
            pane_id,
            "#{&&:#{==:#{window_id}," .. ref.window_id .. "},#{==:#{pane_id}," .. pane_id .. "}}",
            program(argv),
            rejected,
        }
    end
    return {
        "if-shell",
        "-F",
        "-t",
        target,
        condition,
        program(argv),
        rejected,
    }
end

local function prepare_link(state, ref, kind, input, options, inspect, invalid, pane_id)
    local function owned(value, expected)
        if not inspect then
            invalid("operation requires an owned destination", "invalid_target")
        end
        local found, err = inspect(state, value, expected)
        if not found then
            error(err, 0)
        end
        if not rawequal(ref.generation, found.generation) then
            invalid("destination belongs to a different generation", "stale_generation")
        end
        return found
    end
    local function boolean(name)
        if options[name] ~= nil and type(options[name]) ~= "boolean" then
            invalid(name .. " must be boolean")
        end
        return options[name] == true
    end
    local argv = { kind == "break_out" and "break-pane" or targets.window_link[kind] }
    local destination
    local function flag(name, value)
        argv[#argv + 1] = name
        if value ~= nil then
            argv[#argv + 1] = value
        end
    end
    if kind == "select" or kind == "unlink" then
        if input ~= nil then
            invalid("this operation does not accept an input value", "invalid_argument")
        end
        flag("-t", link_target(ref))
        if kind == "unlink" and boolean("kill_if_last") then
            flag("-k")
        end
    else
        flag("-s", link_target(ref) .. (pane_id and "." .. pane_id or ""))
        if kind == "swap" then
            destination = owned(input, "window_link")
            flag("-t", link_target(destination))
            if boolean("select") then
                flag("-d")
            end
        else
            if not plain(input) then
                invalid("destination must be a plain record", "invalid_target")
            end
            for key in next, input do
                if key ~= "session" and key ~= "index" and key ~= "link" and key ~= "position" then
                    invalid("unknown destination field", "invalid_target")
                end
            end
            local replace = boolean("replace")
            if input.session ~= nil then
                if input.link ~= nil or input.position ~= nil or replace then
                    invalid("session destination excludes link, position and replacement")
                end
                local session = owned(input.session, "session")
                if input.index ~= nil and not integer(input.index, 0, 2147483647) then
                    invalid("destination index must be an integer from 0 to 2147483647")
                end
                flag(
                    "-t",
                    session.id .. ":" .. (input.index and string.format("%.0f", input.index) or "")
                )
            elseif input.link ~= nil then
                destination = owned(input.link, "window_link")
                if input.index ~= nil then
                    invalid("link destination excludes index")
                end
                flag("-t", link_target(destination))
                if replace then
                    if input.position ~= "at" or link_target(ref) == link_target(destination) then
                        invalid("replacement requires a different explicit victim at its link")
                    end
                    flag("-k")
                elseif input.position == "before" then
                    flag("-b")
                elseif input.position == "after" and destination.index < 2147483647 then
                    flag("-a")
                else
                    invalid("link destination requires before or after a bounded index")
                end
            else
                invalid("destination requires an owned Session or WindowLink", "invalid_target")
            end
            if not boolean("select") then
                flag("-d")
            end
        end
    end
    if kind == "break_out" then
        if options.name then
            flag("-n", options.name)
        end
        if state.version == "3.7" then
            local multi = {}
            for index, value in ipairs(argv) do
                multi[index] = value
            end
            if not options.name then
                multi[#multi + 1], multi[#multi + 2] = "-n", "libtmux-break-placeholder"
            end
            local commands = { multi }
            if options.name then
                commands[2] = { "rename-window", "-t", pane_id, (options.name:gsub("#", "##")) }
            end
            local encoded, err = command.prepare_program({ commands = commands }, true)
            if not encoded then
                error(err, 0)
            end
            -- Exact 3.7 inverts the multi-pane name test. A placeholder avoids
            -- its NULL path; only a requested multi-pane name needs repair.
            argv = {
                "if-shell",
                "-F",
                "-t",
                pane_id,
                "#{==:#{window_panes},1}",
                program(argv),
                encoded,
            }
        end
    end
    if destination then
        argv = guard(destination, argv)
    end
    return guard(ref, argv, pane_id)
end

local function prepare(state, ref, kind, input, options, inspect)
    local function invalid(message, code)
        error(failure(code or "invalid_options", message, ref, kind), 0)
    end
    local version = type(state.version) == "string" and versions[state.version]
    if not version then
        invalid("topology operations require a supported exact tmux release", "unsupported_version")
    end
    options = options == nil and {} or options
    if not plain(options) then
        invalid("topology options must be a plain record")
    end
    for key in next, options do
        if key ~= "process" and not allowed[kind][key] then
            invalid("unknown topology option")
        end
    end
    if
        ref.kind ~= "window_link"
        and kind ~= "rename"
        and kind ~= "navigate_window"
        and kind ~= "move_to"
        and kind ~= "break_out"
        and input ~= nil
    then
        invalid("this topology operation does not take an input value", "invalid_argument")
    end
    local argv = { targets[ref.kind][kind], "-t", ref.id }
    local function flag(name, value)
        argv[#argv + 1] = name
        if value ~= nil then
            argv[#argv + 1] = type(value) == "number" and string.format("%.0f", value) or value
        end
    end
    local function bytes(value, maximum)
        if
            type(value) ~= "string"
            or #value == 0
            or #value > maximum
            or value:find("\000", 1, true)
        then
            invalid("value must be bounded nonempty NUL-free bytes", "invalid_argument")
        end
        return value
    end
    local function boolean(name)
        if options[name] ~= nil and type(options[name]) ~= "boolean" then
            invalid(name .. " must be boolean")
        end
        return options[name] == true
    end
    if ref.kind == "window_link" then
        argv = prepare_link(state, ref, kind, input, options, inspect, invalid)
    elseif kind == "break_out" then
        local context, err = inspect(state, input.source_link, "window_link")
        if not context then
            error(err, 0)
        end
        if options.name ~= nil then
            bytes(options.name, 1024)
        end
        argv =
            prepare_link(state, context, kind, input.destination, options, inspect, invalid, ref.id)
    elseif kind == "move_to" then
        local target, err = inspect(state, input, "pane")
        if not target then
            error(err, 0)
        end
        if target.id == ref.id then
            invalid("move requires two different panes", "invalid_target")
        end
        local selected = boolean("select")
        if selected and options.target_link == nil then
            invalid("selecting a moved pane requires an explicit target link", "invalid_target")
        end
        local context
        if options.target_link ~= nil then
            context, err = inspect(state, options.target_link, "window_link")
            if not context then
                error(err, 0)
            end
        end
        argv = {
            "join-pane",
            "-s",
            ref.id,
            "-t",
            context and link_target(context) .. "." .. target.id or target.id,
        }
        if
            options.direction ~= nil
            and options.direction ~= "horizontal"
            and options.direction ~= "vertical"
        then
            invalid("pane move direction must be horizontal or vertical")
        end
        flag(options.direction == "horizontal" and "-h" or "-v")
        if options.size ~= nil and options.percent ~= nil then
            invalid("pane move size and percent are mutually exclusive")
        end
        if options.size ~= nil then
            if not integer(options.size, 1, 10000) then
                invalid("pane move size must be an integer from 1 to 10000")
            end
            flag("-l", options.size)
        elseif options.percent ~= nil then
            if not integer(options.percent, 1, 100) then
                invalid("pane move percent must be an integer from 1 to 100")
            end
            flag("-l", string.format("%.0f%%", options.percent))
        end
        if boolean("before") then
            flag("-b")
        end
        if boolean("full_size") then
            flag("-f")
        end
        if not selected then
            flag("-d")
        end
        if context then
            argv = guard(context, argv, target.id)
        end
    elseif kind == "respawn" then
        if not inspect then
            invalid("window respawn requires an owned WindowLink context", "invalid_target")
        end
        local context, err = inspect(state, options.context, "window_link")
        if not context then
            error(err, 0)
        end
        if context.window_id ~= ref.id or not rawequal(context.generation, ref.generation) then
            invalid(
                "respawn context must name this Window in the same generation",
                "invalid_target"
            )
        end
        argv[3] = link_target(context)
        if boolean("kill") then
            flag("-k")
        end
        domain.append_launch(argv, options, invalid)
        argv = guard(context, argv)
    elseif kind == "rename" then
        bytes(input, 1024)
        if ref.kind == "session" and input:find("[.:\001-\031\127]") then
            invalid(
                "session names cannot contain dots, colons or control bytes",
                "invalid_argument"
            )
        end
        flag("--", (input:gsub("#", "##")))
    elseif kind == "navigate_window" then
        local navigation =
            { next = "next-window", previous = "previous-window", last = "last-window" }
        if type(input) ~= "string" or not navigation[input] then
            invalid("window navigation requires next, previous or last", "invalid_argument")
        end
        argv[1] = navigation[input]
        if input == "last" and options.activity ~= nil then
            invalid("last-window does not accept activity filtering")
        end
        if boolean("activity") then
            flag("-a")
        end
    elseif kind == "renumber_windows" then
        flag("-r")
    elseif kind == "resize" then
        local largest, smallest = boolean("largest"), boolean("smallest")
        local dimensions = options.width ~= nil or options.height ~= nil
        local modes = (dimensions and 1 or 0)
            + (options.direction ~= nil and 1 or 0)
            + (largest and 1 or 0)
            + (smallest and 1 or 0)
        if modes ~= 1 or options.amount ~= nil and options.direction == nil then
            invalid("resize requires exactly one of dimensions, direction, largest or smallest")
        end
        if dimensions then
            for _, item in ipairs({ { "width", "-x" }, { "height", "-y" } }) do
                local value = options[item[1]]
                if value ~= nil then
                    if not integer(value, 1, 10000) then
                        invalid("window dimensions must be integers from 1 to 10000")
                    end
                    flag(item[2], value)
                end
            end
        elseif options.direction ~= nil then
            local directions = { left = "-L", right = "-R", up = "-U", down = "-D" }
            local direction = directions[options.direction]
            local amount = options.amount == nil and 1 or options.amount
            if not direction or not integer(amount, 1, 10000) then
                invalid("resize needs a direction and an integer amount from 1 to 10000")
            end
            flag(direction, amount)
        else
            flag(largest and "-A" or "-a")
        end
    elseif kind == "layout" then
        local next_layout, previous, restore =
            boolean("next"), boolean("previous"), boolean("restore")
        local modes = (options.named ~= nil and 1 or 0)
            + (options.layout ~= nil and 1 or 0)
            + (next_layout and 1 or 0)
            + (previous and 1 or 0)
            + (restore and 1 or 0)
        if modes ~= 1 then
            invalid("layout requires exactly one of named, layout, next, previous or restore")
        end
        if options.named ~= nil then
            local minimum = type(options.named) == "string" and layouts[options.named]
            if not minimum then
                invalid("named layout must use a full canonical name", "invalid_argument")
            elseif version < minimum then
                invalid("named layout is unavailable on this tmux release", "unsupported")
            end
            flag("--", options.named)
        elseif options.layout ~= nil then
            local layout = bytes(options.layout, 65536)
            -- Older native parsers read past short headers; 3.3/3.3a also
            -- leave the error cause unset when the checksum header is absent.
            if not layout:match("^%x%x%x%x,.") then
                invalid("custom layout requires a four-digit checksum and body", "invalid_layout")
            end
            flag("--", layout)
        else
            flag(next_layout and "-n" or previous and "-p" or "-o")
        end
    end
    if options.process ~= nil then
        if not plain(options.process) then
            invalid("process options must be a plain record")
        end
        local permitted = {
            timeout = true,
            deadline = true,
            max_output_bytes = true,
            kill_timeout = true,
            drain_timeout = true,
        }
        for key in next, options.process do
            if not permitted[key] then
                invalid("unsupported topology process option")
            end
        end
    end
    local copied, configured, cost =
        execution.prepare(state.runtime, { argv }, options.process, false)
    if not copied then
        error(configured, 0)
    end
    if cost > 1048576 then
        invalid("topology input exceeds one MiB")
    end
    return {
        argv = copied[1],
        options = configured,
        bytes = cost,
        guarded = ref.kind == "window_link"
            or kind == "respawn"
            or kind == "break_out"
            or kind == "move_to" and options.target_link ~= nil,
        cwd = options.cwd,
    }
end

function M.run(state, owned, kind, input, options, inspect)
    local ref, validation_error, plan
    if type(kind) ~= "string" or not allowed[kind] then
        validation_error = failure("invalid_operation", "unknown topology operation", nil, kind)
    else
        ref, validation_error = current(state, owned, kind)
        if ref then
            local ok, value = pcall(prepare, state, ref, kind, input, options, inspect)
            if ok then
                plan = value
            else
                validation_error = value
            end
        end
    end
    local request = state.runtime:_operation(function(_, active)
        if not plan or not ref then
            return nil, validation_error
        end
        local now, err = current(state, owned, kind)
        if not now then
            return nil, err
        end
        if not rawequal(ref.generation, now.generation) then
            return nil,
                failure(
                    "stale_generation",
                    "server generation changed before topology operation",
                    ref,
                    kind
                )
        end
        if plan.cwd then
            local valid
            valid, err = domain.directory(state, plan.cwd, "window.respawn.cwd"):await()
            if not valid then
                return nil, err
            end
        end
        -- Native aliases and hooks can change behavior or wait; submission is
        -- not a transaction and a nonzero exit does not establish rollback.
        active:_set_effect("unknown")
        local result
        result, err = state.bound:execute(plan.argv, plan.options):await()
        result, err = process.retain_output(active, result, err, operation(ref, kind))
        if not result then
            return nil, err
        end
        active:_set_effect("completed")
        now, err = current(state, owned, kind)
        if not now or not rawequal(ref.generation, now.generation) then
            return nil,
                failure(
                    err and err.code or "stale_generation",
                    err and err.message or "server generation changed after topology operation",
                    ref,
                    kind,
                    "completed",
                    { cause = err, partial = result }
                )
        end
        if
            plan.guarded
            and result.stdout == STALE_LINK .. "\n"
            and result.stderr == ""
            and result.exit_code == 0
            and result.signal == 0
        then
            return nil,
                failure(
                    "stale_target",
                    "window link no longer matches its context",
                    ref,
                    kind,
                    "not_sent",
                    { partial = result }
                )
        end
        return true
    end, { operation = operation(ref, kind), effect = "not_sent", target = ref })
    if plan and not request:is_settled() then
        local accepted, cause = request:_retain(plan.bytes)
        if not accepted then
            request:cancel(
                failure(
                    "queue_full",
                    "topology input exceeds runtime byte capacity",
                    ref,
                    kind,
                    nil,
                    { cause = cause }
                )
            )
        end
    end
    return request
end

---@class libtmux.TopologyOptions
---@field process? libtmux.CreationProcessOptions

---@class libtmux.NavigateWindowOptions: libtmux.TopologyOptions
---@field activity? boolean Only next/previous accept this option, including false.

---@class libtmux.ResizeWindowOptions: libtmux.TopologyOptions
---@field width? integer From 1 to 10000; dimensions exclude direction and policies.
---@field height? integer From 1 to 10000.
---@field direction? 'left'|'right'|'up'|'down'
---@field amount? integer From 1 to 10000; defaults to 1 with direction.
---@field largest? boolean Native largest sizing; excludes dimensions and other modes.
---@field smallest? boolean Native smallest sizing; excludes dimensions and other modes.

---@alias libtmux.NamedLayout
---| 'even-horizontal'
---| 'even-vertical'
---| 'main-horizontal'
---| 'main-vertical'
---| 'tiled'
---| 'main-horizontal-mirrored'
---| 'main-vertical-mirrored'

---@class libtmux.LayoutOptions: libtmux.TopologyOptions
---@field named? libtmux.NamedLayout
---@field layout? string Exported checksum-prefixed layout; native validation can unzoom first.
---@field next? boolean Select exactly one of named/layout/next/previous/restore.
---@field previous? boolean
---@field restore? boolean

---@class libtmux.LinkDestination
---@field session? libtmux.Session Excludes link and position.
---@field index? integer Native free index if omitted; excludes link.
---@field link? libtmux.WindowLink Guarded anchor or explicit victim.
---@field position? "before"|"after"|"at" At requires replace=true.

---@class libtmux.SwapLinkOptions: libtmux.TopologyOptions
---@field select? boolean False preserves selected slots; true selects swapped slots.

---@class libtmux.LinkOptions: libtmux.TopologyOptions
---@field select? boolean Defaults to false; removal/replacement may force native selection.
---@field replace? boolean Requires an explicit victim link with position=at.

---@class libtmux.UnlinkOptions: libtmux.TopologyOptions
---@field kill_if_last? boolean Permit destruction if no links survive; defaults to false.

---@class libtmux.RespawnWindowOptions: libtmux.CreationOptions
---@field context libtmux.WindowLink Required placement of this Window.
---@field kill? boolean Permit replacing running pane processes; defaults to false.

---@class libtmux.MovePaneOptions: libtmux.TopologyOptions
---@field direction? "horizontal"|"vertical" Defaults to vertical.
---@field size? integer Cell count from 1 to 10000; excludes percent.
---@field percent? integer Percentage from 1 to 100; excludes size.
---@field before? boolean Place before the target in native geometry.
---@field full_size? boolean Extend across the full window.
---@field select? boolean Defaults to false; true requires target_link.
---@field target_link? libtmux.WindowLink Guarded target pane placement.

---@class libtmux.BreakPaneOptions: libtmux.TopologyOptions
---@field name? string Nonempty native Window name; omitted preserves native default naming.
---@field select? boolean Defaults to false; source removal may force native selection.

return M
