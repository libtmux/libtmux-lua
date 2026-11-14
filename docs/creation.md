# Create sessions, windows and panes

`Server:new_session`, `Session:new_window` and `Pane:split` return a
`Request<Creation>`. Await it inside the adapter's coroutine, or register
`on_complete(value, err)`. Setup and cancellation:
[connections](snapshots.md), [runtime ownership](runtime.md).

The receipt holds `session`, `window`, `pane` and `window_link` handles built
from tmux's returned IDs. Its `created` list names what the call created:

- A session: all four.
- A window: the window, pane and link.
- A split: the pane only.

The other handles describe the containing context. A created pane proves
neither that its program started nor that it succeeded.

## Commands and literal values

- `argv` is a literal command. `shell` is tmux shell text you write. They are
  mutually exclusive, and omitting both uses tmux's default command or shell.
- Several `argv` items run natively. A single executable runs through
  `/usr/bin/env --` so tmux does not read it as a shell string; that needs
  `env` and rejects names containing `=`. Use `shell` for those.
- Names, directories and environment values stay literal, even text that looks
  like a tmux format.
- Session names reject `:`, `.` and control bytes, which tmux would change.
- `environment` maps portable variable names to strings and applies to the new
  session or pane process (tmux `-e`). It does not change your environment.
- `cwd` must be an absolute existing directory. A missing one is rejected
  before the command is sent; later changes to the filesystem are still
  possible.

Input is copied and validated before dispatch, nested process options
included.

## Placement and selection

- **Sessions** start detached and take `name`, `window_name`, `width` and
  `height`.
- **Windows** take `name`, an optional nonnegative `index` and `select`, under
  the Session handle's exact ID. An occupied `index` fails instead of
  replacing the window.
- **Splits** take `direction` (`left`, `right`, `up` or `down`; default down),
  a positive `size` in cells or a `percent` from 1 to 99, `full_size` and
  `select`.

New windows and splits leave the selection alone unless `select = true`.
Editing a handle's reference cannot redirect an operation.

## Errors and limits

- `process` takes `timeout`, `deadline`, `max_output_bytes`, `kill_timeout`
  and `drain_timeout` ([command completion](commands.md)). It cannot replace
  the socket, environment, input stream or working directory.
- One call accepts at most 1,024 `argv` items, 128 environment entries and
  1 MiB of encoded input, within the runtime's shared byte capacity.
- Errors say whether the command was not sent, may have taken effect, or
  completed. A malformed receipt reports `invalid_result` with the command
  output.
- Cancelling the tmux client cannot undo a creation the daemon accepted.
  Creation never retries or removes partial state.
- Closing the Server handle leaves created sessions running.
