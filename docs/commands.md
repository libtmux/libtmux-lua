# Execute tmux commands

After [connecting](snapshots.md), `server:command(argv, options)` submits
literal tmux arguments and returns a Request.

- It keeps raw stdout and stderr bytes, the exit code and the signal, and
  waits for the client and its pipes to finish.
- A nonzero exit is returned as data. A spawn failure, timeout, output limit
  or incomplete drain returns `nil, err`.
- No shell parses `argv`. tmux still parses its own command syntax, and the
  library protects literal separator arguments. A command that takes shell
  text, such as `run-shell`, keeps shell semantics.

## Refused commands

Before sending, the library refuses a literal command that is unsafe on the
connected release. It resolves the command through tmux's aliases and unique
prefixes, so `breakp` and `split` match `break-pane` and `split-window`. A
refusal returns `unsupported` with the required release and
`effect = "not_sent"`. A group with a refused item runs nothing.

| Command | Refused on | Reason |
| --- | --- | --- |
| `delete-buffer -b`, `set-buffer -n` | below 3.4 | A missing buffer name acts on another buffer. |
| `select-layout` with a custom layout that has no checksum header | below 3.4 | tmux 3.3a crashes on an invalid layout. |
| `select-layout` with a JSON layout | below 3.8 | Releases below 3.8 do not read JSON layouts. |
| `split-window -p` | 3.4 | The percentage flag is broken; use `-l N%`. |
| `refresh-client -l` | below 3.6a | tmux 3.3a exits at once when the attached client's `TERM` is `xterm-256color` or `tmux-256color`, and 3.4 through 3.6 can exit when that client leaves before its terminal answers. |
| `break-pane` | exactly 3.7 | tmux 3.7 misnames windows; use `Pane:break_out`. |
| `new-session -s/-n`, `new-window -n`, `rename-session`, `rename-window` with `:` or `.` in the name | exactly 3.7 | tmux 3.7 rejects those names. |

The check reads only the command a literal item starts with. Nothing inside a
command string nested in another command is checked: the argument of
`if-shell` or `run-shell -C`, a brace block, a configured alias, a key binding
or a hook. A refused form written that way reaches tmux, and what it does
depends on the form:

| Nested form | Releases | Failure class |
| --- | --- | --- |
| `break-pane` without `-n` | exactly 3.7 | The server exits ([source][break-pane-3-7]); the next command returns `stale_generation`. |
| `select-layout` with an invalid layout string | 3.3a | The server exits. |
| `refresh-client -l` | 3.3a when the attached client's `TERM` is `xterm-256color` or `tmux-256color` (it survives `screen` and `vt100`); 3.4 through 3.6 when the attached client leaves before its terminal answers | The server can exit. 3.6a fixes the second case ([changes][clipboard-query]). |
| `delete-buffer -b NAME`, `set-buffer -b NAME -n NEW`, with no buffer called `NAME` | below 3.4 | The newest buffer is deleted or renamed instead. |
| `split-window -p` | 3.4 | tmux answers with its own error and nothing changes. |
| `select-layout` with a JSON layout | 3.4 and later, below 3.8 | tmux answers with its own error and nothing changes. |
| `:` or `.` in a session or window name | exactly 3.7 | tmux answers with its own error and nothing changes. |

- On exactly tmux 3.7, `if-shell -F 1 'break-pane -d'` passes the check and
  stops the server, while a plain `break-pane -d` is refused.
- In nested or bound text (the default `prefix !` binding runs `break-pane`,
  [source][prefix-bang]), name the new window with `-n`, or upgrade to tmux
  3.7a, which fixes the crash ([changes][changes-3-7a]). Exactly 3.7 ignores
  the name and uses the default one, so `-n` avoids the crash and nothing more.
- Do not use a plain `break-pane` in nested text there. Called directly, every
  literal `break-pane` is refused on exactly 3.7, with or without `-n`; use
  `Pane:break_out`.

[break-pane-3-7]: https://github.com/tmux/tmux/blob/3.7/cmd-break-pane.c#L117-L124
[prefix-bang]: https://github.com/tmux/tmux/blob/3.7/key-bindings.c#L358
[changes-3-7a]: https://github.com/tmux/tmux/blob/3.7a/CHANGES#L3
[clipboard-query]: https://github.com/tmux/tmux/blob/3.6a/CHANGES#L21

Aliases apply even to full built-in names, including commands the typed
methods use. Hooks can run more commands and change state. The library does
not change a borrowed server's configuration, and cannot stop an alias from
changing before a later command is parsed.

## Groups and batches

`server:group(commands, options)` runs commands in order as one tmux group and
returns one combined output and exit status.

- A parse failure can reject the whole group.
- An immediate execution failure skips the later commands.
- A delayed failure in a WAIT command can still let later commands run.
- A group is not a transaction, and its members have no separate results.

`server:batch(commands, { concurrency = n, process = options })` runs
independent commands. `concurrency` defaults to 1 and is at most 128; runtime
capacity can lower it.

- The result is an array of outcomes by input position: `completed`, `failed`,
  `unknown` or `skipped`, each with `effect` and optionally `value` or `error`.
- A nonzero exit is a `failed` outcome, with the real result in
  `error.partial`. Other commands continue.
- A cancelled batch exposes a frozen `err.partial.outcomes` receipt. It keeps
  the completed results and tells started work from work never sent.

## Limits and options

- Commands and process options are validated and copied before sending.
- One call takes at most 1,024 commands, 4,096 arguments in total and 16 MiB
  of input. NUL is rejected in `argv` and environment entries; stdin may
  contain it.
- Process options: `stdin`, `cwd`, explicit `env` entries, `timeout`,
  monotonic `deadline`, `max_output_bytes` (1 MiB), `drain_timeout` (250 ms)
  and `kill_timeout` (100 ms). Timeouts apply to the client operation.
- Output over the limit is reported with byte counts and truncation metadata,
  never silently kept. Output limits and runtime byte admission are separate.
- Never retry a mutation automatically, especially after an `unknown` effect.
  Cancelling a client does not prove the daemon stopped the work.

## Output routing

Output follows tmux. `run-shell` without a pane target writes its job output to
the pane's view mode on tmux 3.3a and 3.4, and to the waiting client's stdout
from 3.5 on ([upstream change](https://github.com/tmux/tmux/commit/fb37d52ddeccb603b0932b81cff3a6228f1fd83d)).
An explicit `-t` pane target selects pane output. Without `-b`, the client
still waits for the job, and a control-mode `%end` marker can arrive before
that completion.

The raw API is an escape hatch. A successful `send-keys` process does not
report whether the pane's program exited.
