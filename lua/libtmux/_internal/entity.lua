local errors = require("libtmux._internal.error")
local graph = require("libtmux._internal.graph")
local identity = require("libtmux._internal.identity")
local domain = require("libtmux._internal.domain")
local pane = require("libtmux._internal.pane")
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
    return pane.run(stored.server, stored.identity, "resize", nil, options)
end

function Entity:kill(options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "kill", nil, options)
end

function Entity:respawn(options)
    local stored = handles[self]
    return pane.run(stored.server, stored.identity, "respawn", nil, options)
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
---@field resize fun(self:libtmux.Entity<T>,options:libtmux.ResizePaneOptions):
--- libtmux.Request<boolean>
---@field kill fun(self:libtmux.Entity<T>,options?:libtmux.PaneOptions):
--- libtmux.Request<boolean>
---@field respawn fun(self:libtmux.Entity<T>,options?:libtmux.RespawnOptions):
--- libtmux.Request<boolean>

return M
