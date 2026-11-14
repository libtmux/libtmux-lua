# Switch and detach clients

Name a client by its name and TTY from a snapshot. A selector addresses the
attachment currently at that name, including a replacement that attached after
the snapshot. A client record does not prove the attachment is the same one.

Inside a [runtime task](runtime.md), with a connected `server`, choose the
client and the destination session by their observed names:

```lua
local snapshot = assert(server:snapshot():await())
local observed = snapshot.clients:where({ name = "/dev/pts/7" }):one()
local record = snapshot.sessions:where({ name = "work" }):one()
local destination = assert(server:handle(snapshot, record))
local selector = { name = observed.name, tty = observed.tty }
assert(server:switch_client(selector, destination):await())
```

- `switch_client` needs a Session handle from the same Server. Its private
  session ID picks the destination, so editing a returned reference cannot
  redirect it.
- Switching keeps the destination's environment. Pass
  `{ update_environment = true }` to apply the client's `update-environment`
  values. tmux's attachment, selection, sizing, focus and lifecycle effects
  still happen.
- `server:detach_client(selector)` detaches that one client. It does not
  detach all clients or signal a parent process or shell. Success means the
  detach command completed, not that the client's terminal process exited.
  Closing the library connection leaves other clients attached.
- Both resolve to `true` on completion.

## Selection and failure

- The selector is a plain record with only `name` and `tty`, each an exact
  NUL-free string of at most 4,096 bytes. `name` must be nonempty; `tty` may be
  empty for a client without a terminal. There is no implicit current client
  and no abbreviated name.
- A fresh listing checks the full name and TTY pair and tmux's lookup aliases.
  A missing pair returns `missing_target` and several matches return
  `ambiguous_target`. Neither sends a mutation.
- The listing and the mutation are separate commands, so another attachment
  can replace the client between them. No PID or timestamp check can prove
  continuity across a detach, exec and reconnect. Use these methods only when
  you mean the current attachment.
- Selectors and options are copied before I/O. A closed handle or stale
  generation rejects the work.
- A failure before dispatch has `effect = "not_sent"`. Cancelling after
  dispatch may leave the effect unknown. If continuity is lost after success,
  the result keeps the receipt and `effect = "completed"`. Mutations are never
  retried. Aliases and hooks follow [command execution](commands.md).

`process` options: `timeout`, `deadline`, `max_output_bytes`, `drain_timeout`
and `kill_timeout`.

- The output cap defaults to 1 MiB and cannot be raised.
- Each subprocess has its own timeout, and an absolute deadline also bounds
  the later ones.
- Preflight accepts at most 1,024 client rows. A malformed or oversized
  listing fails without touching a target.
- Runtime byte capacity covers input, listing data and receipts until
  delivery.

## Interactive attachment

`session:attach()` returns `unsupported_tty` before spawning: the luv and
Neovim adapters own no interactive terminal. It does not borrow the editor's
terminal or turn a control observation into an attachment. Terminal ownership,
client navigation, key tables and read-only toggles are not implemented.
