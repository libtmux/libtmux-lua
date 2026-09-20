local settings = require("libtmux._internal.settings")
local environment = require("libtmux._internal.environment")
local buffer = require("libtmux._internal.buffer")
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

---@class libtmux.Entity<T>
---@field get_option fun(self:libtmux.Entity<T>,name:string,options?:libtmux.SettingOptions):
--- libtmux.Request<libtmux.OptionRecord>
---@field list_options fun(self:libtmux.Entity<T>,options?:libtmux.SettingOptions):
--- libtmux.Request<libtmux.OptionRecord[]>
---@field set_option fun(self:libtmux.Entity<T>,name:string,value:libtmux.OptionInput,
--- options?:libtmux.SettingOptions):
--- libtmux.Request<boolean>
---@field unset_option fun(self:libtmux.Entity<T>,name:string,options?:libtmux.SettingOptions):
--- libtmux.Request<boolean>
---@field get_hook fun(self:libtmux.Entity<T>,name:string,options?:libtmux.SettingOptions):
--- libtmux.Request<libtmux.HookRecord>
---@field list_hooks fun(self:libtmux.Entity<T>,options?:libtmux.SettingOptions):
--- libtmux.Request<libtmux.HookRecord[]>
---@field set_hook fun(self:libtmux.Entity<T>,name:string,value:libtmux.HookProgram,
--- options?:libtmux.SettingOptions):
--- libtmux.Request<boolean>
---@field unset_hook fun(self:libtmux.Entity<T>,name:string,options?:libtmux.SettingOptions):
--- libtmux.Request<boolean>
---@field run_hook fun(self:libtmux.Entity<T>,name:string,options?:libtmux.SettingOptions):
--- libtmux.Request<boolean>
---@field get_environment fun(self:libtmux.Entity<T>,name:string,
--- options?:libtmux.EnvironmentOptions):
--- libtmux.Request<libtmux.EnvironmentRecord>
---@field list_environment fun(self:libtmux.Entity<T>,options?:libtmux.EnvironmentOptions):
--- libtmux.Request<libtmux.EnvironmentRecord[]>
---@field set_environment fun(self:libtmux.Entity<T>,name:string,value:string,
--- options?:libtmux.EnvironmentOptions):
--- libtmux.Request<boolean>
---@field unset_environment fun(self:libtmux.Entity<T>,name:string,
--- options?:libtmux.EnvironmentOptions):
--- libtmux.Request<boolean>
---@field remove_environment fun(self:libtmux.Entity<T>,name:string,
--- options?:libtmux.EnvironmentOptions):
--- libtmux.Request<boolean>
---@field reference fun(self:libtmux.Entity<T>):libtmux.Reference?, libtmux.Error?
---@field snapshot fun(self:libtmux.Entity<T>):libtmux.Request<T>
---@field new_window fun(self:libtmux.Entity<T>,options?:libtmux.NewWindowOptions):
--- libtmux.Request<libtmux.Creation>
---@field split fun(self:libtmux.Entity<T>,options?:libtmux.SplitOptions):
--- libtmux.Request<libtmux.Creation>
---@field capture fun(self:libtmux.Entity<T>,options?:libtmux.CaptureOptions):
--- libtmux.Request<libtmux.Capture>
---@field send_text fun(self:libtmux.Entity<T>,text:string,options?:libtmux.PaneOptions):
--- libtmux.Request<boolean>
---@field send_keys fun(self:libtmux.Entity<T>,keys:string[],options?:libtmux.KeyOptions):
--- libtmux.Request<boolean>
---@field copy_mode fun(self:libtmux.Entity<T>,options?:libtmux.CopyModeOptions):
--- libtmux.Request<boolean>
---@field copy_command fun(self:libtmux.Entity<T>,action:string,
--- args?:string[],options?:libtmux.KeyOptions):libtmux.Request<boolean>
---@field resize fun(self:libtmux.Entity<T>,
--- options:libtmux.ResizePaneOptions|libtmux.ResizeWindowOptions):
--- libtmux.Request<boolean>
---@field kill fun(self:libtmux.Entity<T>,options?:libtmux.PaneOptions):
--- libtmux.Request<boolean>
---@field respawn fun(self:libtmux.Entity<T>,
--- options?:libtmux.RespawnOptions|libtmux.RespawnWindowOptions):
--- libtmux.Request<boolean>
---@field select fun(self:libtmux.Entity<T>,
--- options?:libtmux.SelectPaneOptions|libtmux.TopologyOptions):
--- libtmux.Request<boolean>
---@field set_title fun(self:libtmux.Entity<T>,text:string,options?:libtmux.PaneOptions):
--- libtmux.Request<boolean>
---@field swap fun(self:libtmux.Entity<T>,
--- other:libtmux.Entity<libtmux.SnapshotPane>|libtmux.Entity<libtmux.SnapshotWindowLink>,
--- options?:libtmux.SwapPaneOptions|libtmux.SwapLinkOptions):libtmux.Request<boolean>
---@field link fun(self:libtmux.Entity<T>,destination:libtmux.LinkDestination,
--- options?:libtmux.LinkOptions):libtmux.Request<boolean>
---@field move fun(self:libtmux.Entity<T>,destination:libtmux.LinkDestination,
--- options?:libtmux.LinkOptions):libtmux.Request<boolean>
---@field unlink fun(self:libtmux.Entity<T>,options?:libtmux.UnlinkOptions):
--- libtmux.Request<boolean>
---@field move_to fun(self:libtmux.Entity<T>,other:libtmux.Entity<libtmux.SnapshotPane>,
--- options?:libtmux.MovePaneOptions):libtmux.Request<boolean>
---@field break_out fun(self:libtmux.Entity<T>,
--- source_link:libtmux.Entity<libtmux.SnapshotWindowLink>,
--- destination:libtmux.LinkDestination,options?:libtmux.BreakPaneOptions):libtmux.Request<boolean>
---@field rename fun(self:libtmux.Entity<T>,name:string,options?:libtmux.TopologyOptions):
--- libtmux.Request<boolean>
---@field navigate_window fun(self:libtmux.Entity<T>,direction:"next"|"previous"|"last",
--- options?:libtmux.NavigateWindowOptions):libtmux.Request<boolean>
---@field renumber_windows fun(self:libtmux.Entity<T>,options?:libtmux.TopologyOptions):
--- libtmux.Request<boolean>
---@field layout fun(self:libtmux.Entity<T>,options:libtmux.LayoutOptions):
--- libtmux.Request<boolean>
---@field paste_buffer fun(self:libtmux.Entity<T>,name:string,options?:libtmux.PasteBufferOptions):
--- libtmux.Request<boolean>

return M
