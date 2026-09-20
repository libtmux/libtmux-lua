# Switch and detach clients

Use an explicit client name and TTY from a snapshot. A selector addresses the
current attachment at that name, including a replacement that attached after
the snapshot. Client records do not prove attachment continuity.

Inside a [runtime task](runtime.md), with a connected `server`, choose the
client and destination session by their observed names:

```lua
local snapshot = assert(server:snapshot():await())
local observed = snapshot.clients:where({ name = "/dev/pts/7" }):one()
local record = snapshot.sessions:where({ name = "work" }):one()
local destination = assert(server:handle(snapshot, record))
local selector = { name = observed.name, tty = observed.tty }
assert(server:switch_client(selector, destination):await())
```

`switch_client` requires a Session handle from the same Server. Its private
session ID determines the destination; changing a returned reference cannot
redirect the request. By default, switching preserves the destination's
environment. Set `{ update_environment = true }` to apply the client's native
`update-environment` values. Switching still triggers tmux's attachment,
selection, sizing, focus and lifecycle effects.

`server:detach_client(selector)` detaches that current client. It neither
detaches all clients nor requests a parent-process signal or shell command.
Success means the native detach command completed; it does not mean the
borrowed terminal process was reaped. Closing the library connection leaves
other attached clients running.

Both methods return Requests that resolve to `true` on native completion.
The [owned-terminal fixture](../tests/integration/test_client.py) runs these
[public API operations](../tests/integration/client.lua) through standalone
Lua and Neovim, including same-process reconnection and environment updates.

## Selection and failure

The selector must be a plain record containing only `name` and `tty`.
Both are exact NUL-free byte strings of at most 4,096 bytes. `name` must be
nonempty; `tty` may be empty for a client without a terminal. No implicit
current client or abbreviated name is selected.

A fresh listing checks the complete name/TTY pair and native lookup aliases.
Missing pairs return `missing_target`; multiple native matches return
`ambiguous_target`. Neither dispatches a mutation. The listing and mutation
are separate commands: another attachment can replace the selected client
between them. No PID or timestamp check can prove continuity across native
detach/exec/reconnect. Use these methods only when addressing the current
attachment is the intended operation.

Selectors and options are copied before I/O. Closed handles and stale daemon
generations reject work. A failure before mutation dispatch has
`effect = "not_sent"`; cancellation after dispatch may have an unknown effect.
Continuity loss after success retains the native receipt and
`effect = "completed"`. Mutations are never retried automatically. Native
aliases and hooks follow the [command execution contract](commands.md).

The `process` options accept `timeout`, `deadline`, `max_output_bytes`,
`drain_timeout` and `kill_timeout`. The output cap defaults to one MiB and
cannot exceed it. Each subprocess has its own timeout; an absolute deadline
also bounds later subprocesses. Preflight accepts at most 1,024 client rows.
Malformed or oversized listings fail without mutating a target. Runtime byte
capacity covers input, listing data and native receipts through delivery.

## Interactive attachment

`session:attach()` returns `unsupported_tty` before spawning: the current luv
and Neovim adapters do not own an interactive terminal. It does not borrow
the editor's terminal or turn a control observation into an interactive
attachment. Interactive terminal ownership, client navigation, key tables
and read-only toggles remain pending capabilities.
