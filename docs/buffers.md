# Read and paste named buffers

Buffers hold bytes in the tmux daemon. Use an explicit name for every read,
write, deletion and paste; these methods never infer the most recent buffer.
Each live operation returns a Request through the PROCESS endpoint.

```lua
assert(server:set_buffer("build-output", "one\000two\n"):await())
local content = assert(server:show_buffer("build-output"):await())
assert(content.bytes == "one\000two\n")
assert(pane:paste_buffer("build-output", {
    bytes = "raw",
    linefeed_separator = true,
}):await())
```

The executable [integration fixture](../tests/integration/buffer.lua) includes
connection setup, owned pane readers, output barriers and teardown.

## Storage and identity

`server:set_buffer(name, bytes)` replaces the current value at that name.
Input accepts one byte through one MiB, including NUL, invalid UTF-8 and
trailing newlines. It uses native stdin loading, so no shell or argv decoder
processes the value. Empty input is rejected with `invalid_argument`: tmux
would accept it without creating or clearing a buffer. Delete explicitly to
remove the value.

New names must be nonempty UTF-8, at most 4,096 bytes, without NUL, ASCII
controls, DEL or backslash. The excluded creation forms return
`unsupported_name`; some tmux releases accept them, while newer name cleaning
can change their stored key. Further native name validation still applies.
Spaces, leading dashes and `#{...}` are literal. Buffer names do not undergo
tmux format expansion.

`server:show_buffer(name)` returns `{ name, bytes }` with a pure `text()`
method. `bytes` preserves exact stdout. `text()` requires valid UTF-8 and
performs no trimming, replacement or newline normalization. Invalid UTF-8
returns `nil, err` with `invalid_utf8`. Mutating this returned record changes
neither the daemon's value nor future Requests.

`server:delete_buffer(name)` removes the current value. Read, delete and paste
also accept broader exact observed names: nonempty NUL-free strings up to
4,096 bytes. A missing buffer retains tmux's error and native receipt.

A name identifies a current slot, not a persistent buffer incarnation. Another
client can replace its value after a snapshot or read. These methods operate
on the value present when tmux executes them; no preflight or transaction
claim hides that possibility.

## Paste behavior

`pane:paste_buffer(name, options)` targets the handle's exact pane ID and adds
no Enter. Completion means the native command finished; it does not prove an
application received or consumed the bytes.

| Option | Behavior |
| --- | --- |
| `bytes = "native"` | Default: preserve the connected daemon's native policy. tmux 3.7+ sanitizes control and invalid UTF-8 bytes; earlier releases paste raw bytes. |
| `bytes = "raw"` | Disable that sanitization with `-S` on 3.7+; earlier releases already behave this way. Newline conversion remains separately controlled. |
| `linefeed_separator = true` | Preserve LF. By default, tmux changes each LF to CR. |
| `separator = text` | Replace each LF with this bounded NUL-free string, including empty. Excludes `linefeed_separator`, even explicit false. |
| `bracket = true` | Add native bracketed-paste wrappers only when the pane has enabled that terminal mode. |
| `delete_after = true` | Remove the named buffer after native paste processing. |

Input-disabled panes can accept paste without receiving bytes, including a
successful `delete_after`. Paste does not use the send-keys dispatcher; do not
assume its copy-mode or synchronized-pane routing. Native aliases and hooks
remain observable as described in [command execution](commands.md).

## Bounds and effects

Options must be plain records and are copied before dispatch. The nested
`process` options accept timeout, deadline, output limit and drain/kill limits
from [Pane operations](panes.md). Buffer output defaults to one MiB and cannot
be raised above that bound. Overflow returns an error with available partial
output, never a successful truncated BufferValue.

Runtime input and output reservations remain charged through delivery.
Closed or stale generations reject new work; continuity lost after native
success preserves `effect = "completed"` and the receipt. Cancellation after
dispatch can have an unknown effect and never retries the mutation or kills
the target pane.

Binary append, buffer renaming and explicit file load/save remain pending
typed APIs. No read-concatenate-write operation is presented as atomic.
