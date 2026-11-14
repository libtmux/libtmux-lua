# Persistent environment

Server methods address tmux's global environment store, and Session methods
that session's local store. Each method returns a Request, and reads never
evaluate shell text. Window and Pane handles reject these operations with
`invalid_scope`.

Use a disposable server with at least one session at `/tmp/example-tmux.sock`.
This example changes `APP_MODE` in its global and session stores.

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

- Names match `[A-Za-z_][A-Za-z0-9_]*` and fit in 256 bytes. tmux accepts some
  other names; this API returns `unsupported_name` for them.
- Values are NUL-free byte strings up to 1 MiB. Empty strings, newlines,
  quotes, dollar signs and invalid UTF-8 stay bytes, with no interpolation.

## Reads and storage source

`get_environment(name, options)` returns one record.
`list_environment(options)` returns records sorted by portable name.

| Field | Meaning |
| --- | --- |
| `name` | Portable name |
| `state` | `value`, `removed` or `absent`; lists omit absent names |
| `value` | Exact bytes for `value`, including an empty string |
| `hidden` | tmux's visibility flag; omitted when absent |
| `scope` | Storage source: `global` or `session` |
| `inherited` | Whether a session read fell back to the global store |
| `target` | Session reference when the source is a session |

- Reads use local storage by default (`inherit = false`). A session read with
  `inherit = true` falls back to global storage only when the name is absent
  locally. A local hidden entry or removal marker blocks the fallback.
- If neither store has the name, the absent record describes the requested
  session.
- Named reads detect hidden entries. Lists include hidden entries by default;
  `include_hidden = false` omits them. An inherited list still reads local
  hidden entries, so a hidden override cannot expose a global value. Treat
  hidden values as sensitive.
- `scope` must match the receiver: `global` for Server, `session` for Session.
  `inherit = true` needs a session read, and `include_hidden` applies only to
  lists. Other combinations fail before I/O.

## Mutations and inheritance

- `set_environment(name, value, { hidden = true })` stores a hidden value.
  Without `hidden` it stores an ordinary value and clears any hidden flag.
- `unset_environment(name)` deletes the entry, letting a session fall back to
  the global store.
- `remove_environment(name)` installs a removal marker that blocks the
  fallback and keeps the entry's existing hidden flag.
- Each mutation returns `true` once tmux completes.

These stores affect newly spawned processes, not running ones. A merged read is
not the exact environment of a future process: tmux adds variables of its own
and may take `PATH` from the creating client.

## Consistency and bounds

- Reads run literal `show-environment -s` arguments through a bounded decoder,
  never a shell evaluator. The decoder knows the supported releases'
  [dialects](../lua/libtmux/_internal/environment_codec.lua), including their
  printer escapes, and an unlisted release fails explicitly.
- A listing of a nonportable removal name can look like several portable
  removal rows. Before returning a list, the library re-reads each parsed
  removal by name, in the same scope and visibility, in groups of at most 128
  commands. A missing, duplicate, extra or changed row returns `inconsistent`.
  Nonportable assignments fail decoding.
- Several reads are not a transaction: tmux can change between observations.
  Nothing is retried.
- One operation reads at most 1 MiB of stdout and stderr in total and 4,096
  source entries, counting both visibility views, the global fallback and the
  verification output. Runtime capacity covers copied input, raw output and
  decoded records until delivery. A capacity or protocol error returns no
  partial list.
- `process` takes `timeout`, `deadline`, `max_output_bytes`, `drain_timeout`
  and `kill_timeout`; the output limit cannot exceed 1 MiB. A timeout applies
  to each client, and an absolute deadline also bounds later ones. Stdin,
  environment and working-directory overrides are not available.
- A closed handle or stale generation rejects dispatch or publication.
  Cancelling cannot undo work the daemon accepted. tmux errors keep their
  receipt, and a decoding or consistency failure after a successful read has
  `effect = "completed"`.
