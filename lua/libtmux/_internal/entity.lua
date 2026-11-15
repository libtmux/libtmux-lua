local settings = require("libtmux._internal.settings")
local environment = require("libtmux._internal.environment")
local buffer = require("libtmux._internal.buffer")
local client = require("libtmux._internal.client")
local errors = require("libtmux._internal.error")
local graph = require("libtmux._internal.graph")
local identity = require("libtmux._internal.identity")
local domain = require("libtmux._internal.domain")
local pane = require("libtmux._internal.pane")
local topology = require("libtmux._internal.topology")
local M, Entity = {}, {}
local handles = setmetatable({}, { __mode = "kv" })

local function reference(stored)
    if stored.server.closed then
        return nil,
            errors.new("closed", "server handle is closed", {
                operation = "reference",
                effect = "not_sent",
            })
    end
    local generation, err = stored.server.bound:generation()
    if not generation then
        return nil, err
    end
    return identity.inspect(generation, stored.identity)
end

local function key(ref)
    if ref.kind == "window_link" then
        return ref.session_id .. ":" .. ref.index .. ":" .. ref.window_id
    elseif ref.kind == "client" then
        return ref.name .. "\000" .. ref.tty
    end
    return ref.id or ref.name
end

local function from_identity(state, owned)
    local stored = { server = state, identity = owned, methods = Entity }
    local ref, err = reference(stored)
    if not ref then
        return nil, err
    end
    stored.kind = ref.kind
    local handle = setmetatable({}, {
        __index = function(_, name)
            return stored.methods[name]
        end,
        __metatable = "libtmux.Entity",
    })
    handles[handle] = stored
    return handle
end

function M.from_snapshot(state, snapshot, record)
    local owned, err = graph.handle(snapshot, record)
    if not owned then
        return nil, err
    end
    return from_identity(state, owned)
end

function M.from_reference(state, ref)
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    local owned
    owned, err = identity.bind(generation, ref)
    if not owned then
        return nil, err
    end
    return from_identity(state, owned)
end

function Entity:get_option(name, options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "option", "get", name, nil, options)
end

function Entity:list_options(options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "option", "list", nil, nil, options)
end

function Entity:set_option(name, value, options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "option", "set", name, value, options)
end

function Entity:unset_option(name, options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "option", "unset", name, nil, options)
end

function Entity:get_hook(name, options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "hook", "get", name, nil, options)
end

function Entity:list_hooks(options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "hook", "list", nil, nil, options)
end

function Entity:set_hook(name, value, options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "hook", "set", name, value, options)
end

function Entity:unset_hook(name, options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "hook", "unset", name, nil, options)
end

function Entity:run_hook(name, options)
    local stored = handles[self]
    return settings.run(stored.server, stored.identity, "hook", "run", name, nil, options)
end

function Entity:get_environment(name, options)
    local stored = handles[self]
    return environment.run(stored.server, stored.identity, "get", name, nil, options)
end

function Entity:list_environment(options)
    local stored = handles[self]
    return environment.run(stored.server, stored.identity, "list", nil, nil, options)
end

function Entity:set_environment(name, value, options)
    local stored = handles[self]
    return environment.run(stored.server, stored.identity, "set", name, value, options)
end

function Entity:unset_environment(name, options)
    local stored = handles[self]
    return environment.run(stored.server, stored.identity, "unset", name, nil, options)
end

function Entity:remove_environment(name, options)
    local stored = handles[self]
    return environment.run(stored.server, stored.identity, "remove", name, nil, options)
end

function Entity:reference()
    return reference(handles[self])
end

function Entity:attach()
    local stored = handles[self]
    return client.attach(stored.server, stored.identity)
end

function M.inspect(state, handle, kind)
    local stored = handles[handle]
    if not stored or not rawequal(stored.server, state) then
        return nil,
            errors.new("invalid_target", "entity handle belongs to another server", {
                operation = "reference",
                effect = "not_sent",
            })
    end
    local ref, err = reference(stored)
    if not ref then
        return nil, err
    end
    if kind and ref.kind ~= kind then
        return nil,
            errors.new("invalid_target", "entity handle has the wrong kind", {
                operation = "reference",
                effect = "not_sent",
            })
    end
    return ref
end

function Entity:capture(options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "capture", nil, options)
end

function Entity:wait_for_text(text, options)
    local stored = handles[self]
    return pane.wait_for_text(stored.server, stored.identity, text, options)
end

function Entity:clear_history(options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "clear_history", nil, options)
end

function Entity:capture_to_buffer(name, options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "capture_to_buffer", name, options)
end

function Entity:send_text(text, options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "send_text", text, options)
end

function Entity:send_keys(keys, options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "send_keys", keys, options)
end

function Entity:copy_mode(options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "copy_mode", nil, options)
end

function Entity:copy_command(action, args, options)
    local stored = handles[self]
    return pane.run(
        stored.server,
        stored.identity,
        "copy_command",
        { action = action, args = args },
        options
    )
end

function Entity:resize(options)
    local stored = handles[self]
    local implementation = stored.kind == "pane" and pane or topology
    return implementation.run(stored.server, stored.identity, "resize", nil, options)
end

function Entity:kill(options)
    local stored = handles[self]
    local implementation = stored.kind == "pane" and pane or topology
    return implementation.run(stored.server, stored.identity, "kill", nil, options)
end

function Entity:rename(name, options)
    local stored = handles[self]
    return topology.run(stored.server, stored.identity, "rename", name, options)
end

function Entity:navigate_window(direction, options)
    local stored = handles[self]
    return topology.run(stored.server, stored.identity, "navigate_window", direction, options)
end

function Entity:renumber_windows(options)
    local stored = handles[self]
    return topology.run(stored.server, stored.identity, "renumber_windows", nil, options)
end

function Entity:layout(options)
    local stored = handles[self]
    return topology.run(stored.server, stored.identity, "layout", nil, options)
end

function Entity:respawn(options)
    local stored = handles[self]
    local implementation = stored.kind == "window" and topology or pane
    return implementation.run(stored.server, stored.identity, "respawn", nil, options, M.inspect)
end

function Entity:select(options)
    local stored = handles[self]
    local implementation = stored.kind == "window_link" and topology or pane
    return implementation.run(stored.server, stored.identity, "select", nil, options)
end

function Entity:link(destination, options)
    local stored = handles[self]
    return topology.run(stored.server, stored.identity, "link", destination, options, M.inspect)
end

function Entity:move(destination, options)
    local stored = handles[self]
    return topology.run(stored.server, stored.identity, "move", destination, options, M.inspect)
end

function Entity:unlink(options)
    local stored = handles[self]
    return topology.run(stored.server, stored.identity, "unlink", nil, options)
end

function Entity:move_to(other, options)
    local stored = handles[self]
    return topology.run(stored.server, stored.identity, "move_to", other, options, M.inspect)
end

function Entity:break_out(source_link, destination, options)
    local stored = handles[self]
    return topology.run(
        stored.server,
        stored.identity,
        "break_out",
        { source_link = source_link, destination = destination },
        options,
        M.inspect
    )
end

function Entity:set_title(text, options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "set_title", text, options)
end

function Entity:paste_buffer(name, options)
    local stored = handles[self]
    return buffer.run(stored.server, stored.identity, "paste", name, nil, options)
end

function Entity:swap(other, options)
    local stored = handles[self]
    local implementation = stored.kind == "window_link" and topology or pane
    return implementation.run(stored.server, stored.identity, "swap", other, options, M.inspect)
end

function Entity:new_window(options)
    local stored = handles[self]
    return domain.create(stored.server, stored.identity, "window", options, M.from_reference)
end

function Entity:split(options)
    local stored = handles[self]
    return domain.create(stored.server, stored.identity, "pane", options, M.from_reference)
end

function Entity:snapshot(options)
    local stored = handles[self]
    return stored.server.runtime:_operation(function(_, operation)
        if options ~= nil then
            return nil,
                errors.new("invalid_options", "entity snapshot takes no options", {
                    operation = "entity.snapshot",
                    effect = "not_sent",
                })
        end
        local ref, err = reference(stored)
        if not ref then
            return nil, err
        end
        operation:_set_effect("unknown")
        local snapshot
        local captured = stored.server.capture()
        snapshot, err = captured:await()
        local admitted, cause = operation:_retain(captured._cost)
        if not admitted then
            return nil,
                errors.new("queue_full", "entity result exceeds retained byte capacity", {
                    operation = "entity.snapshot",
                    effect = err and err.effect or "completed",
                    cause = cause,
                    target = ref,
                })
        end
        if not snapshot then
            return nil, err
        end
        local value
        value, err = graph.lookup(snapshot, ref.kind, key(ref))
        if not value then
            return nil,
                err or errors.new(
                    "target_missing",
                    "captured entity no longer exists in its context",
                    {
                        operation = "entity.snapshot",
                        effect = "completed",
                        target = ref,
                    }
                )
        end
        return value
    end, { operation = "entity.snapshot", effect = "not_sent" })
end

---@class libtmux.Reference
---@field kind string
---@field generation table
---@field id? string
---@field name? string
---@field tty? string
---@field session_id? string
---@field window_id? string
---@field index? integer

--- A handle to one tmux object, bound to the snapshot generation it came from.
--- Every handle kind can report its reference and refresh its snapshot record;
--- the concrete classes below add what tmux allows for that kind.
---@class libtmux.Entity<T>
---@field reference fun(self:libtmux.Entity<T>):libtmux.Reference?, libtmux.Error?
--- Resolves the handle's current identity without sending a command.
---@field snapshot fun(self:libtmux.Entity<T>):libtmux.Request<T> Re-reads this object's record.

--- Options and hooks, shared by sessions, windows and panes.
--- Scopes are limited to the handle's own kind; global scopes belong to the Server.
---@class libtmux.Configurable<T>: libtmux.Entity<T>
---@field get_option fun(self:libtmux.Configurable<T>,name:string,
--- options?:libtmux.SettingGetOptions):
--- libtmux.Request<libtmux.OptionRecord> Reads one option.
---@field list_options fun(self:libtmux.Configurable<T>,options?:libtmux.SettingListOptions):
--- libtmux.Request<libtmux.OptionRecord[]> Lists the options set at this scope.
---@field set_option fun(self:libtmux.Configurable<T>,name:string,value:libtmux.OptionInput,
--- options?:libtmux.SettingSetOptions):
--- libtmux.Request<boolean> Sets one option.
---@field unset_option fun(self:libtmux.Configurable<T>,name:string,
--- options?:libtmux.SettingUnsetOptions):
--- libtmux.Request<boolean> Unsets one option.
---@field get_hook fun(self:libtmux.Configurable<T>,name:string,options?:libtmux.SettingGetOptions):
--- libtmux.Request<libtmux.HookRecord> Reads one hook.
---@field list_hooks fun(self:libtmux.Configurable<T>,options?:libtmux.SettingListOptions):
--- libtmux.Request<libtmux.HookRecord[]> Lists the hooks set at this scope.
---@field set_hook fun(self:libtmux.Configurable<T>,name:string,value:libtmux.HookProgram,
--- options?:libtmux.SettingSetOptions):
--- libtmux.Request<boolean> Sets one hook.
---@field unset_hook fun(self:libtmux.Configurable<T>,name:string,
--- options?:libtmux.SettingUnsetOptions):
--- libtmux.Request<boolean> Unsets one hook.
---@field run_hook fun(self:libtmux.Configurable<T>,name:string,options?:libtmux.RunHookOptions):
--- libtmux.Request<boolean> Runs one hook now.

--- A tmux session.
---
--- A session handle is bound to the snapshot generation it came from. A method
--- that talks to tmux returns a `libtmux.Request`; a failed request reports a
--- `libtmux.Error`.
---
--- # What is on here
---
--- The methods fall into a few groups:
---
--- **Finding the session.** Take one record from a `libtmux.Snapshot` with
--- `libtmux.Selection:one`, which reports no match or several as errors, and pass
--- it with its snapshot to `libtmux.Server:handle`, which returns the handle
--- directly rather than as a request. `libtmux.Entity:reference` names the
--- handle's identity without sending a command, and `libtmux.Entity:snapshot`
--- reads the session's record again, reporting `target_missing` when it is gone.
---
--- `libtmux.Selection:one`, `libtmux.Server:handle`, `libtmux.Entity:reference`
--- and `libtmux.Entity:snapshot`
---
--- **Looking inside a session.** A handle holds no children. Read them from the
--- snapshot record, which leads to each relation without another command.
---
--- `libtmux.SnapshotSession.window_links`, `libtmux.SnapshotWindowLink.window`
--- and `libtmux.SnapshotWindow.panes`
---
--- **Creating a window.** `libtmux.Session:new_window` resolves to a
--- `libtmux.Creation` with handles for the window and its pane. The new window
--- is detached unless `select = true`. `name` takes up to 1024 bytes without NUL,
--- `index` takes a nonnegative integer, and the command comes from `argv`, a
--- literal argument list, or from an explicit `shell`, never both.
---
--- `libtmux.Session:new_window`
---
--- **Renaming and moving between windows.** A session name takes up to 1024 bytes
--- and cannot contain dots, colons or control bytes, which fail as
--- `invalid_argument`. Navigation selects the next,
--- previous or last window, and renumbering closes gaps in window indexes.
---
--- `libtmux.Session:rename`, `libtmux.Session:navigate_window` and
--- `libtmux.Session:renumber_windows`
---
--- **Options, hooks and environment.** Options and hooks are limited to the
--- session's own scope; the global scopes belong to the Server. In the
--- environment, unset marks a name as removed from new processes, and remove
--- deletes it from the session.
---
--- `libtmux.Configurable:get_option`, `libtmux.Configurable:list_options`,
--- `libtmux.Configurable:set_option`, `libtmux.Configurable:unset_option`,
--- `libtmux.Configurable:get_hook`, `libtmux.Configurable:list_hooks`,
--- `libtmux.Configurable:set_hook`, `libtmux.Configurable:unset_hook`,
--- `libtmux.Configurable:run_hook`, `libtmux.Session:get_environment`,
--- `libtmux.Session:list_environment`, `libtmux.Session:set_environment`,
--- `libtmux.Session:unset_environment` and `libtmux.Session:remove_environment`
---
--- **Things that need a terminal.** `libtmux.Session:attach` returns
--- `unsupported_tty`, because the luv and Neovim adapters do not own an
--- interactive terminal.
---
--- `libtmux.Session:attach`
---
--- **Removing the session.** Killing removes this session.
---
--- `libtmux.Session:kill`
---@class libtmux.Session: libtmux.Configurable<libtmux.SnapshotSession>
---@field new_window fun(self:libtmux.Session,options?:libtmux.NewWindowOptions):
--- libtmux.Request<libtmux.Creation> Creates a window in this session.
---@field rename fun(self:libtmux.Session,name:string,options?:libtmux.TopologyOptions):
--- libtmux.Request<boolean> Renames this session.
---@field kill fun(self:libtmux.Session,options?:libtmux.TopologyOptions):
--- libtmux.Request<boolean> Kills this session.
---@field navigate_window fun(self:libtmux.Session,direction:"next"|"previous"|"last",
--- options?:libtmux.NavigateWindowOptions):libtmux.Request<boolean> Selects another window.
---@field renumber_windows fun(self:libtmux.Session,options?:libtmux.TopologyOptions):
--- libtmux.Request<boolean> Closes gaps in window indexes.
---@field attach fun(self:libtmux.Session):libtmux.Request<boolean>
--- Requires an interactive terminal capability; current adapters return unsupported_tty.
---@field get_environment fun(self:libtmux.Session,name:string,
--- options?:libtmux.EnvironmentGetOptions):
--- libtmux.Request<libtmux.EnvironmentRecord> Reads one environment variable.
---@field list_environment fun(self:libtmux.Session,options?:libtmux.EnvironmentListOptions):
--- libtmux.Request<libtmux.EnvironmentRecord[]> Lists this session's environment.
---@field set_environment fun(self:libtmux.Session,name:string,value:string,
--- options?:libtmux.EnvironmentSetOptions):
--- libtmux.Request<boolean> Sets one environment variable.
---@field unset_environment fun(self:libtmux.Session,name:string,
--- options?:libtmux.EnvironmentOptions):
--- libtmux.Request<boolean> Marks one variable as removed from new processes.
---@field remove_environment fun(self:libtmux.Session,name:string,
--- options?:libtmux.EnvironmentOptions):
--- libtmux.Request<boolean> Deletes one variable from this session's environment.

--- A tmux window. Placement in a session belongs to its window links.
---
--- A window handle is bound to the snapshot generation it came from. A method
--- that talks to tmux returns a `libtmux.Request`; a failed request reports a
--- `libtmux.Error`.
---
--- # What is on here
---
--- The methods fall into a few groups:
---
--- **Finding the window.** Take one record from a `libtmux.Snapshot` with
--- `libtmux.Selection:one` and pass it with its snapshot to
--- `libtmux.Server:handle`, which returns the handle directly rather than as a
--- request. A window link's record leads to its window.
--- `libtmux.Entity:snapshot` reads the window's record again, reporting
--- `target_missing` when it is gone.
---
--- `libtmux.Selection:one`, `libtmux.Server:handle`,
--- `libtmux.SnapshotWindowLink.window` and `libtmux.Entity:snapshot`
---
--- **Looking inside a window.** A handle holds no children. Read panes and
--- placements from the snapshot record, which leads to each relation without
--- another command.
---
--- `libtmux.SnapshotWindow.panes`, `libtmux.SnapshotWindow.window_links` and
--- `libtmux.SnapshotPane.window`
---
--- **Arranging.** A resize takes exactly one of dimensions, from 1 to 10000, a
--- direction with an optional amount, `largest` or `smallest`. A layout takes
--- exactly one of a named layout, an exported layout string, `next`, `previous`
--- or `restore`. Respawning needs the `context` window link of this window in
--- the same snapshot generation, and replaces running processes only with
--- `kill = true`.
---
--- `libtmux.Window:resize`, `libtmux.Window:layout` and `libtmux.Window:respawn`
---
--- **Placing in sessions.** A window link is one placement, so these methods live
--- on `libtmux.WindowLink`. Linking, moving and unlinking take a destination,
--- and unlinking the last placement destroys the window only with
--- `kill_if_last = true`.
---
--- `libtmux.WindowLink:select`, `libtmux.WindowLink:swap`,
--- `libtmux.WindowLink:link`, `libtmux.WindowLink:move` and
--- `libtmux.WindowLink:unlink`
---
--- **Changing things.** A window name takes up to 1024 bytes without NUL. Killing
--- removes the window from every session that links it.
---
--- `libtmux.Window:rename` and `libtmux.Window:kill`
---
--- **Options and hooks.** Limited to the window's own scope; the global scopes
--- belong to the Server.
---
--- `libtmux.Configurable:get_option`, `libtmux.Configurable:list_options`,
--- `libtmux.Configurable:set_option`, `libtmux.Configurable:unset_option`,
--- `libtmux.Configurable:get_hook`, `libtmux.Configurable:list_hooks`,
--- `libtmux.Configurable:set_hook`, `libtmux.Configurable:unset_hook` and
--- `libtmux.Configurable:run_hook`
---@class libtmux.Window: libtmux.Configurable<libtmux.SnapshotWindow>
---@field rename fun(self:libtmux.Window,name:string,options?:libtmux.TopologyOptions):
--- libtmux.Request<boolean> Renames this window.
---@field kill fun(self:libtmux.Window,options?:libtmux.TopologyOptions):
--- libtmux.Request<boolean> Kills this window in every session that links it.
---@field resize fun(self:libtmux.Window,options:libtmux.ResizeWindowOptions):
--- libtmux.Request<boolean> Resizes this window.
---@field layout fun(self:libtmux.Window,options:libtmux.LayoutOptions):
--- libtmux.Request<boolean> Applies a layout to this window's panes.
---@field respawn fun(self:libtmux.Window,options:libtmux.RespawnWindowOptions):
--- libtmux.Request<boolean> Restarts this window's command; needs a context link.

--- One placement of a window in a session: a window can be linked into several.
---@class libtmux.WindowLink: libtmux.Entity<libtmux.SnapshotWindowLink>
---@field select fun(self:libtmux.WindowLink,options?:libtmux.TopologyOptions):
--- libtmux.Request<boolean> Makes this the session's current window.
---@field swap fun(self:libtmux.WindowLink,other:libtmux.WindowLink,
--- options?:libtmux.SwapLinkOptions):libtmux.Request<boolean> Exchanges two placements.
---@field link fun(self:libtmux.WindowLink,destination:libtmux.LinkDestination,
--- options?:libtmux.LinkOptions):libtmux.Request<boolean> Links this window somewhere else too.
---@field move fun(self:libtmux.WindowLink,destination:libtmux.LinkDestination,
--- options?:libtmux.LinkOptions):libtmux.Request<boolean> Moves this placement.
---@field unlink fun(self:libtmux.WindowLink,options?:libtmux.UnlinkOptions):
--- libtmux.Request<boolean> Removes this placement.

--- A tmux pane.
---
--- A pane handle is bound to the snapshot generation it came from. A method that
--- talks to tmux returns a `libtmux.Request`; a failed request reports a
--- `libtmux.Error`.
---
--- # What is on here
---
--- The methods fall into a few groups:
---
--- **Finding the pane.** Take one record from a `libtmux.Snapshot` with
--- `libtmux.Selection:one` and pass it with its snapshot to
--- `libtmux.Server:handle`, which returns the handle directly rather than as a
--- request. A window's record lists its panes. `libtmux.Entity:snapshot` reads
--- the pane's record again, reporting `target_missing` when it is gone.
---
--- `libtmux.Selection:one`, `libtmux.Server:handle`, `libtmux.SnapshotWindow.panes`
--- and `libtmux.Entity:snapshot`
---
--- **Sending input.** Text goes to the pane literally. Keys are names as tmux's
--- send-keys reads them, and `repeat_count` runs from 1 to 1000.
---
--- `libtmux.Pane:send_text` and `libtmux.Pane:send_keys`
---
--- **Reading output.** A capture resolves to a `libtmux.Capture` whose `bytes`
--- are the exact stdout and whose `text` method checks strict UTF-8. It reads
--- the visible screen unless `history_lines`, or `start_line` and `end_line`,
--- ask for more; the two ways are mutually exclusive. Several options need a
--- newer tmux, such as `mode_screen` on 3.6. Waiting polls the visible screen
--- for literal text and returns `deadline_exceeded` when `timeout` expires.
---
--- `libtmux.Pane:capture`, `libtmux.Pane:wait_for_text` and
--- `libtmux.Pane:capture_to_buffer`
---
--- **Splitting and arranging.** A split resolves to a `libtmux.Creation`. It goes
--- down by default, takes `size` or `percent` but not both, and is detached
--- unless `select = true`. Resizing takes dimensions or a direction, not both.
--- Moving a pane joins it beside another; breaking out gives it a window of its
--- own.
---
--- `libtmux.Pane:split`, `libtmux.Pane:resize`, `libtmux.Pane:select`,
--- `libtmux.Pane:swap`, `libtmux.Pane:move_to` and `libtmux.Pane:break_out`
---
--- **Copy mode and buffers.** Enter copy mode and run a copy-mode command, paste
--- a named buffer, or clear history. Buffers are addressed by explicit name.
---
--- `libtmux.Pane:copy_mode`, `libtmux.Pane:copy_command`,
--- `libtmux.Pane:paste_buffer` and `libtmux.Pane:clear_history`
---
--- **Changing things.** Respawning restarts the pane's command, and replaces a
--- running program only with `kill = true`. Killing removes the pane.
---
--- `libtmux.Pane:respawn`, `libtmux.Pane:set_title` and `libtmux.Pane:kill`
---
--- **Options and hooks.** Limited to the pane's own scope; the global scopes
--- belong to the Server.
---
--- `libtmux.Configurable:get_option`, `libtmux.Configurable:list_options`,
--- `libtmux.Configurable:set_option`, `libtmux.Configurable:unset_option`,
--- `libtmux.Configurable:get_hook`, `libtmux.Configurable:list_hooks`,
--- `libtmux.Configurable:set_hook`, `libtmux.Configurable:unset_hook` and
--- `libtmux.Configurable:run_hook`
---@class libtmux.Pane: libtmux.Configurable<libtmux.SnapshotPane>
---@field send_keys fun(self:libtmux.Pane,keys:string[],options?:libtmux.KeyOptions):
--- libtmux.Request<boolean> Sends key names, as tmux's send-keys reads them.
---@field send_text fun(self:libtmux.Pane,text:string,options?:libtmux.PaneOptions):
--- libtmux.Request<boolean> Sends literal text.
---@field capture fun(self:libtmux.Pane,options?:libtmux.CaptureOptions):
--- libtmux.Request<libtmux.Capture> Captures the screen, and history on request.
---@field wait_for_text fun(self:libtmux.Pane,text:string,options?:libtmux.WaitTextOptions):
--- libtmux.Request<libtmux.TextWait> Polls the visible screen until it contains the literal text.
---@field split fun(self:libtmux.Pane,options?:libtmux.SplitOptions):
--- libtmux.Request<libtmux.Creation> Splits this pane.
---@field kill fun(self:libtmux.Pane,options?:libtmux.PaneOptions):
--- libtmux.Request<boolean> Kills this pane.
---@field select fun(self:libtmux.Pane,options?:libtmux.SelectPaneOptions):
--- libtmux.Request<boolean> Makes this the window's active pane.
---@field resize fun(self:libtmux.Pane,options:libtmux.ResizePaneOptions):
--- libtmux.Request<boolean> Resizes this pane.
---@field respawn fun(self:libtmux.Pane,options?:libtmux.RespawnOptions):
--- libtmux.Request<boolean> Restarts this pane's command.
---@field set_title fun(self:libtmux.Pane,text:string,options?:libtmux.PaneOptions):
--- libtmux.Request<boolean> Sets the pane title.
---@field clear_history fun(self:libtmux.Pane,options?:libtmux.ClearHistoryOptions):
--- libtmux.Request<boolean> Clears history and exits pane modes.
---@field capture_to_buffer fun(self:libtmux.Pane,name:string,options?:libtmux.CaptureOptions):
--- libtmux.Request<boolean> Stores native bytes; empty capture leaves the buffer unchanged.
---@field paste_buffer fun(self:libtmux.Pane,name:string,options?:libtmux.PasteBufferOptions):
--- libtmux.Request<boolean> Pastes a named buffer into this pane.
---@field copy_mode fun(self:libtmux.Pane,options?:libtmux.CopyModeOptions):
--- libtmux.Request<boolean> Enters copy mode.
---@field copy_command fun(self:libtmux.Pane,action:string,
--- args?:string[],options?:libtmux.KeyOptions):libtmux.Request<boolean> Runs a copy-mode command.
---@field swap fun(self:libtmux.Pane,other:libtmux.Pane,options?:libtmux.SwapPaneOptions):
--- libtmux.Request<boolean> Exchanges two panes.
---@field move_to fun(self:libtmux.Pane,other:libtmux.Pane,options?:libtmux.MovePaneOptions):
--- libtmux.Request<boolean> Joins this pane beside another.
---@field break_out fun(self:libtmux.Pane,source_link:libtmux.WindowLink,
--- destination:libtmux.LinkDestination,options?:libtmux.BreakPaneOptions):
--- libtmux.Request<boolean> Moves this pane into a window of its own.

--- A client attached to the server.
---@class libtmux.Client: libtmux.Entity<libtmux.SnapshotClient>

--- A paste buffer. Buffer contents are read and written through the Server.
---@class libtmux.Buffer: libtmux.Entity<libtmux.SnapshotBuffer>

return M
