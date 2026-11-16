-- Capability registry: the tmux releases each optional feature needs.
-- "Support" means the tmux releases this library works with, not helper code.
-- features.lua refuses with these thresholds, and scripts/emit_capabilities.lua
-- serializes this same table to capabilities.json, so the two cannot disagree.
-- Release names are inferred from the daemon's version; tmux advertises none.
local fields = require("libtmux._internal.fields")
local M = {}

local RAW = { "libtmux.Server:command", "libtmux.Server:batch", "libtmux.Server:group" }
local REFUSAL = "libtmux.Error"

-- Lua 5.1 has no table.unpack.
local function plus(first, list)
    local out = {}
    for _, name in ipairs(first) do
        out[#out + 1] = name
    end
    for _, name in ipairs(list) do
        out[#out + 1] = name
    end
    return out
end

---@class libtmux.CapabilityCommand
---@field command string
---@field flags string[]?

---@class libtmux.Capability
---@field id string
---@field name string
---@field summary string
---@field since string
---@field except string[]
---@field handling "refuse"|"fallback"|"repair"
---@field error string?
---@field apis string[]
---@field commands libtmux.CapabilityCommand[]

---@type libtmux.Capability[]
M.capabilities = {
    {
        id = "control-mode",
        name = "Control mode observation",
        summary = "Server:observe attaches a library-managed control client and streams events.",
        since = "3.7",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = { "libtmux.Server:observe" },
        commands = { { command = "attach-session", flags = { "-E", "-f", "-t" } } },
    },
    {
        id = "buffer-delete-named",
        name = "Named buffer deletion",
        summary = "Delete one paste buffer by name without risking another buffer.",
        since = "3.4",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = plus({ "libtmux.Server:delete_buffer" }, RAW),
        commands = { { command = "delete-buffer", flags = { "-b" } } },
    },
    {
        id = "buffer-rename",
        name = "Buffer rename",
        summary = "Rename a paste buffer without risking another buffer.",
        since = "3.4",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = RAW,
        commands = { { command = "set-buffer", flags = { "-n" } } },
    },
    {
        id = "layout-without-checksum",
        name = "Layouts without a checksum",
        summary = "Apply a layout string or a named layout that tmux validates before use.",
        since = "3.4",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = RAW,
        commands = { { command = "select-layout" } },
    },
    {
        id = "layout-mirrored-main",
        name = "Mirrored main layouts",
        summary = "Window:layout applies main-horizontal-mirrored and main-vertical-mirrored.",
        since = "3.5",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = { "libtmux.Window:layout" },
        commands = { { command = "select-layout" } },
    },
    {
        id = "layout-json",
        name = "JSON layouts",
        summary = "Window:layout applies a layout in the JSON form tmux reports.",
        since = "3.8",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = { "libtmux.Window:layout" },
        commands = { { command = "select-layout" } },
    },
    {
        id = "capture-trim-blank-cells",
        name = "Trim blank cells in captures",
        summary = "Pane:capture stops each row at the last used cell.",
        since = "3.4",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = { "libtmux.Pane:capture", "libtmux.Pane:capture_to_buffer" },
        commands = { { command = "capture-pane", flags = { "-T" } } },
    },
    {
        id = "capture-line-flags",
        name = "Line flags in captures",
        summary = "Pane:capture prefixes each captured row with its line flags.",
        since = "3.7",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = { "libtmux.Pane:capture", "libtmux.Pane:capture_to_buffer" },
        commands = { { command = "capture-pane", flags = { "-F" } } },
    },
    {
        id = "clipboard-query",
        name = "Clipboard query",
        summary = "Ask an attached client's terminal for its clipboard with refresh-client -l.",
        since = "3.6a",
        except = {},
        handling = "refuse",
        error = REFUSAL,
        apis = RAW,
        commands = { { command = "refresh-client", flags = { "-l" } } },
    },
}

-- Release defects the library works around; they are not capabilities.
-- required is the release the refusal tells the caller to use instead; it is
-- left out when no release fixes the defect for this daemon.
---@type table[]
M.workarounds = {
    {
        id = "break-pane-misnames-windows",
        name = "break-pane window naming",
        summary = "break-pane misnames the new window on exactly tmux 3.7; "
            .. "the raw command is refused, use Pane:break_out.",
        releases = { "3.7" },
        required = "3.7a",
        handling = "refuse",
        apis = RAW,
        commands = { { command = "break-pane" } },
    },
    {
        id = "break-out-rename-repair",
        name = "Pane:break_out window naming",
        summary = "Pane:break_out names the new window itself, which repairs "
            .. "break-pane's misnaming on exactly tmux 3.7.",
        releases = { "3.7" },
        required = "3.7a",
        handling = "repair",
        apis = { "libtmux.Pane:break_out" },
        commands = { { command = "break-pane" } },
    },
    {
        id = "split-window-percent-size",
        name = "split-window -p",
        summary = "split-window -p is broken on tmux 3.4; use -l N%.",
        releases = { "3.4" },
        handling = "refuse",
        apis = RAW,
        commands = { { command = "split-window", flags = { "-p" } } },
    },
    {
        id = "name-separators-rejected",
        name = "Colon and dot in names",
        summary = "tmux 3.7 rejects ':' and '.' in session and window names.",
        releases = { "3.7" },
        required = "3.7a",
        handling = "refuse",
        apis = plus({
            "libtmux.Server:new_session",
            "libtmux.Session:new_window",
            "libtmux.Session:rename",
            "libtmux.Window:rename",
        }, RAW),
        commands = {
            { command = "new-session", flags = { "-s" } },
            { command = "new-window", flags = { "-n" } },
            { command = "rename-session" },
            { command = "rename-window" },
        },
    },
}

local function find(list, id)
    for _, entry in ipairs(list) do
        if entry.id == id then
            return entry
        end
    end
    error("unknown capability or workaround: " .. tostring(id), 3)
end

---@param id string
---@return string since
function M.since(id)
    return find(M.capabilities, id).since
end

---@param id string
---@return table workaround
function M.workaround(id)
    return find(M.workarounds, id)
end

---@class libtmux.CapabilityStatus: libtmux.Capability
---@field supported boolean Whether the observed release provides this feature.

---@class libtmux.WorkaroundStatus
---@field id string
---@field name string
---@field summary string
---@field releases string[] Exact releases affected by this workaround.
---@field required string? First release that fixes this defect, when known.
---@field handling "refuse"|"repair"
---@field apis string[]
---@field commands libtmux.CapabilityCommand[]
---@field active boolean Whether the observed release needs this workaround.

---@class libtmux.CapabilityReport
---@field version string Observed daemon release, independent of the client binary.
---@field features table<string, libtmux.CapabilityStatus> Named feature decisions and requirements.
---@field workarounds table<string, libtmux.WorkaroundStatus> Release-specific defects and handling.

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

local function contains(values, version)
    for _, value in ipairs(values) do
        if value == version then
            return true
        end
    end
    return false
end

-- Each report owns its nested metadata; caller edits cannot change admission.
---@param version string
---@return libtmux.CapabilityReport
function M.report(version)
    local report = { version = version, features = {}, workarounds = {} }
    for _, entry in ipairs(M.capabilities) do
        local status = copy(entry)
        status.supported = fields.at_least(version, entry.since) == true
            and not contains(entry.except, version)
        report.features[entry.id] = status
    end
    for _, entry in ipairs(M.workarounds) do
        local status = copy(entry)
        status.active = contains(entry.releases, version)
        report.workarounds[entry.id] = status
    end
    return report
end

return M
