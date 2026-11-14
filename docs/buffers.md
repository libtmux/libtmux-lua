# Read and paste named buffers

Buffers hold bytes in the tmux daemon. Name a buffer for every read, write,
delete and paste; these methods never pick the most recent one. Each live
operation returns a Request.

```lua
assert(server:set_buffer("build-output", "one\000two\n"):await())
local content = assert(server:show_buffer("build-output"):await())
assert(content.bytes == "one\000two\n")
assert(pane:paste_buffer("build-output", {
    bytes = "raw",
    linefeed_separator = true,
}):await())
```

## Storage and identity

`server:set_buffer(name, bytes)` replaces the value at that name.

- Input is 1 byte to 1 MiB, NUL, invalid UTF-8 and trailing newlines
  included. It loads through tmux's stdin, so no shell or argv decoder touches
  it.
- Empty input is rejected with `invalid_argument`: tmux would accept it
  without creating or clearing a buffer. Delete the buffer to remove its value.
- A new name is nonempty UTF-8 of at most 4,096 bytes, with no NUL, ASCII
  control, DEL or backslash. Other forms return `unsupported_name`: some tmux
  releases accept them, but newer name cleaning can change the stored key.
- Spaces, leading dashes and `#{...}` are literal. Names are never format
  expanded.

`server:show_buffer(name)` returns `{ name, bytes }` with a `text()` method.

- `bytes` is the exact stdout. `text()` needs valid UTF-8, does no trimming,
  replacement or newline normalization, and otherwise returns `nil, err` with
  `invalid_utf8`.
- Changing the returned record changes nothing in the daemon or in later
  Requests.

`server:delete_buffer(name)` removes the value on tmux 3.4 and later.

- On 3.3a it returns `unsupported` before sending: that release can delete
  the most recent buffer when the name is missing, and checking first would
  race with other clients.
- A literal `delete-buffer -b` or `set-buffer -n` through `server:command` is
  refused on the same releases. `paste_buffer` with `delete_after` is not
  affected: its lookup rejects a missing name before deleting.

Read, delete and paste accept any nonempty NUL-free name up to 4,096 bytes. For
a missing buffer they keep tmux's error and receipt.

[`pane:capture_to_buffer(name, options)`](panes.md#capture-and-text) stores a
pane capture directly, under the same creation-name rules. An empty capture
leaves the slot alone, and a buffer capture omits the newline a printed
capture ends with.

A name identifies the current slot, not a lasting buffer. Another client can
replace the value after a snapshot or read, and these methods act on whatever
is there when tmux runs them. There is no preflight or transaction.

## Paste behavior

`pane:paste_buffer(name, options)` targets the handle's exact pane and adds no
Enter. Completion means tmux finished the command, not that a program received
the bytes.

| Option | Behavior |
| --- | --- |
| `bytes = "native"` | Default: the daemon's own policy. tmux 3.7+ sanitizes control and invalid UTF-8 bytes; earlier releases paste raw bytes. |
| `bytes = "raw"` | Turn that sanitization off with `-S` on 3.7+; earlier releases already behave this way. Newline conversion is controlled separately. |
| `linefeed_separator = true` | Keep LF. By default tmux changes each LF to CR. |
| `separator = text` | Replace each LF with this NUL-free string, which may be empty. Excludes `linefeed_separator`, even `false`. |
| `bracket = true` | Add bracketed-paste wrappers when the pane has enabled that terminal mode. |
| `delete_after = true` | Remove the buffer after the paste is processed. |

- An input-disabled pane can accept a paste without receiving bytes, a
  successful `delete_after` included.
- Paste does not use the `send-keys` path, so do not assume its copy-mode or
  synchronized-pane routing.
- Aliases and hooks still apply, as in [command execution](commands.md).

## Bounds and effects

- Options are plain records, copied before sending. The nested `process`
  options take the timeouts and output limit from
  [commands](commands.md).
- Output defaults to 1 MiB and cannot be raised. Overflow returns an error
  with the partial output, never a truncated success.
- Runtime input and output reservations stay charged until delivery.
- A closed handle or stale generation rejects new work. If continuity is lost
  after tmux succeeded, the result keeps `effect = "completed"` and the
  receipt.
- Cancelling after dispatch can leave the effect unknown. It never retries
  the mutation or kills the pane.

Binary append, buffer renaming and explicit file load and save are not
implemented, and no read-concatenate-write is atomic.
