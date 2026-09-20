# Create sessions, windows and panes

`Server:new_session`, `Session:new_window` and `Pane:split` return a
`Request<Creation>`. Await inside the adapter's managed coroutine, or register
`on_complete(value, err)`. See [connections](snapshots.md) and
[runtime ownership](runtime.md) for setup and cancellation.

The receipt contains `session`, `window`, `pane` and `window_link` handles
made from tmux's returned IDs. Its `created` sequence names the objects this
operation created: all four for a session, window/pane/link for a window, and
only the pane for a split. Other handles describe the containing context.
Creating a pane proves neither application readiness nor command success.

## Commands and literal values

Pass `argv` for a literal command, or `shell` for explicitly authored tmux
shell text. They are mutually exclusive. Multiple arguments use tmux's native
argument execution. A singleton executable uses `/usr/bin/env --` to avoid
tmux's single-argument shell interpretation; it requires that utility and
rejects executable names containing `=`. Use explicit shell text for that
case. Omitting both fields uses tmux's configured default command or shell.

Names, directories and environment values stay literal, including tmux
format-looking text. Session names reject `:`, `.`, and control bytes because
tmux would otherwise change them. `environment` maps portable variable names
to string values and applies to the created session or pane process through
tmux's `-e` semantics. It does not change the caller's environment.

An explicit `cwd` must be an absolute existing directory. The asynchronous
preflight rejects a missing directory before sending the creation command.
Filesystem changes after validation remain possible. Input is copied and
validated before dispatch, including nested process options.

## Placement and selection

Sessions start detached and accept `name`, `window_name`, `width` and
`height`. Windows accept `name`, an optional nonnegative `index`, and
`select`; their parent is the Session handle's exact ID. A supplied occupied
index fails rather than replacing the existing window.

Splits accept `direction` (`left`, `right`, `up` or `down`), optional positive
`size` in cells or `percent` from 1 through 99, `full_size`, and `select`. The default
direction is down. New windows and splits leave selection unchanged unless
`select=true`. Handle references cannot be edited to redirect an operation.

## Errors and limits

`process` accepts `timeout`, `deadline`, `max_output_bytes`, `kill_timeout`
and `drain_timeout`; see [command completion](commands.md). It cannot replace
the bound socket, process environment, input stream or working directory.
Creation accepts at most 1024 argv items, 128 environment entries and one MiB
of encoded input, subject to the runtime's shared byte capacity.

Errors preserve whether the command was not sent, may have taken effect, or
completed. A malformed receipt reports `invalid_result` with completed effect
and retained command output. Canceling the tmux client cannot undo a creation
already accepted by the daemon. Creation does not retry or remove partial
state. Closing the Server connection leaves created sessions running.

The [public creation fixture](../tests/integration/domain.lua) exercises the
same API through luv and Neovim with literal arguments, environment and
directory values, returned IDs, explicit shell text and missing directories.
