# Persistent environment

Server methods address tmux's global environment store. Session methods address
that session's local store. Each method returns a Request; reads never evaluate
shell text. Window and Pane handles reject these operations with `invalid_scope`.

```lua
local adapter = require("libtmux.runtime.luv")
local result, err = adapter.run(function(runtime)
    local server = assert(runtime:connect({
        binary = "/usr/bin/tmux",
        socket_path = "/tmp/example-tmux.sock",
        config_path = "/dev/null",
    }):await())
    local snapshot = assert(server:snapshot():await())
    local session = assert(server:handle(snapshot, snapshot.sessions[1]))
    assert(server:set_environment("APP_MODE", "global"):await())
    assert(session:set_environment("APP_MODE", "local"):await())
    local local_value = assert(session:get_environment("APP_MODE"):await())
    assert(session:unset_environment("APP_MODE"):await())
    local inherited = assert(session:get_environment("APP_MODE", { inherit = true }):await())
    return { local_value = local_value, inherited = inherited }
end)
assert(result, tostring(err))
```

Names must match `[A-Za-z_][A-Za-z0-9_]*` and fit within 256 bytes. Native tmux
accepts some other names; this API returns `unsupported_name` for them. Values
are NUL-free byte strings up to one MiB. Empty strings, embedded newlines,
quotes, dollar signs and invalid UTF-8 remain bytes without interpolation.

## Reads and storage source

`get_environment(name, options)` returns one record.
`list_environment(options)` returns records sorted by portable name. Records
have these fields:

| Field | Meaning |
| --- | --- |
| `name` | Portable name |
| `state` | `value`, `removed`, or `absent`; lists omit absent names |
| `value` | Exact bytes for `value`, including an empty string |
| `hidden` | Native visibility flag; omitted when absent |
| `scope` | Storage source: `global` or `session` |
| `inherited` | Whether a session read used global fallback |
| `target` | Session reference when the source is a session |

Reads default to local storage, with `inherit = false`. A session read with
`inherit = true` uses global storage only when the name is absent locally.
Local hidden entries and removal markers suppress fallback. If both stores
lack a named entry, the returned absent record describes the requested session.

Named reads detect hidden entries automatically. Lists include hidden entries
by default; `include_hidden = false` omits them. An inherited list still reads
local hidden entries to prevent a hidden override from exposing a global value.
Treat returned hidden values as sensitive application data.

The optional `scope` must match the receiver: `global` for Server, `session`
for Session. `inherit = true` requires a session read. `include_hidden` applies
only to lists. Unsupported option combinations fail before I/O.

## Mutations and inheritance

`set_environment(name, value, { hidden = true })` stores a hidden value.
Omitting `hidden` stores an ordinary value and clears an existing hidden flag.
`unset_environment(name)` deletes the stored entry, allowing global fallback
for a session. `remove_environment(name)` installs a removal marker that blocks
fallback and preserves the entry's existing native hidden flag. Each mutation
returns `true` after native completion.

These stores influence newly spawned processes. They do not change the
environment of processes already running. A merged read is not an exact future
process environment: tmux also supplies variables and may obtain PATH from the
creating client.

## Consistency and bounds

Reads use literal `show-environment -s` arguments and a bounded decoder, never a
shell evaluator. The decoder recognizes the thirteen catalog releases from
3.2a through 3.7c. It reverses the 3.4–3.5a printer escapes and the additional
3.4 variable-like dollar escape. Unsupported releases fail explicitly.

A listing of a nonportable removal name can resemble several portable removal
rows. Before returning a list, the library verifies each parsed removal through
named reads in the same scope and visibility, in groups of at most 128 commands.
Missing, duplicate, extra or changed verification rows produce `inconsistent`.
The verification uses aggregate group completion and makes no per-member effect
claims. Nonportable assignments fail decoding. This verification does not make
multiple reads a transaction: concurrent native changes can still occur between
observations. There is no automatic retry.

An operation reads at most one MiB of aggregate stdout and stderr and 4096
source entries, including both visibility views and global fallback. Verification
output counts toward the byte limit. Runtime capacity accounts for copied
input, raw output and decoded records through callback delivery. Capacity and
protocol errors return no partial list.

`process` accepts `timeout`, `deadline`, `max_output_bytes`, `drain_timeout` and
`kill_timeout`; its output limit cannot exceed one MiB. A timeout applies to each
native client; an absolute deadline also bounds later clients. Process stdin,
environment and working-directory overrides are unavailable here.

Closed handles and stale generations reject dispatch or publication. Once a
client is sent, cancellation cannot undo accepted daemon work. Native errors
retain their receipt; decoding or consistency failures after successful reads
have `effect = "completed"`.
