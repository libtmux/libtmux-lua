# Execute tmux commands

After [connecting](snapshots.md), `server:command(argv, options)` submits
literal tmux arguments and returns a Request. It preserves raw stdout/stderr
bytes, exit code and signal, and waits for the owned client and its pipes to
retire. A completed nonzero exit is returned as result data. Spawn, timeout,
output-limit and incomplete-drain failures return `nil, err`.

No shell parses argv. tmux still parses its own command syntax; the library
protects literal separator arguments. A tmux command that explicitly accepts
shell text, such as `run-shell`, retains that command's shell semantics.

Before dispatch, the library refuses a literal command item that is unsafe on
the connected daemon's release. The check resolves the command through tmux's
own alias and unique-prefix rules, so `breakp` and `split` match `break-pane`
and `split-window`. A refusal returns `unsupported` with the required release,
`effect = "not_sent"` and no process; a group with a refused item runs
nothing. The refused forms are:

| Command | Refused on | Reason |
| --- | --- | --- |
| `delete-buffer -b`, `set-buffer -n` | below 3.4 | A missing buffer name acts on another buffer. |
| `select-layout` with a custom layout that has no checksum header | below 3.4 | tmux 3.3a crashes on an invalid layout. |
| `split-window -p` | 3.4 | The percentage flag is broken; use `-l N%`. |
| `break-pane` | exactly 3.7 | tmux 3.7 misnames windows; use `Pane:break_out`. |
| `new-session -s/-n`, `new-window -n`, `rename-session`, `rename-window` with `:` or `.` in the name | exactly 3.7 | tmux 3.7 rejects those names. |

The check does not look inside a tmux command string nested in another
command, such as the argument of `if-shell`, `run-shell -C` or a brace block,
and it does not look inside the contents of configured command aliases. Do not
nest a command from the table above: the nested copy reaches tmux unchecked and
can crash a daemon on the releases listed. Shell text that a command runs, such
as the body of `run-shell`, keeps native semantics.

Native command aliases apply even to full built-in names, including commands
used by typed domain methods. Hooks can run additional commands and affect
state. The library does not change borrowed server configuration or promise
that aliases preserve built-in semantics. A preliminary configuration check
cannot prevent an alias from changing before a later command is parsed.

Use `server:group(commands, options)` for an explicit ordered tmux command
group. Its result is aggregate output and exit status. Parse failure can
reject the whole group, immediate execution failure skips later commands,
and delayed WAIT-command failures can still allow later commands. A group
provides neither transactions nor independently attributed member results.

Output routing also follows tmux: `run-shell` without a pane target writes
job output to pane view mode on tmux 3.3a and 3.4; tmux 3.5 onward
writes it to the waiting client's stdout. An explicit `-t` pane target
selects pane output. Without `-b`, client completion still waits for the job,
and a control-mode `%end` marker can precede that completion. See the upstream
[stdout restoration](https://github.com/tmux/tmux/commit/fb37d52ddeccb603b0932b81cff3a6228f1fd83d).

Use `server:batch(commands, { concurrency = n, process = options })` for
independent commands. Concurrency defaults to one and is bounded at 128;
runtime capacity can reduce the active pool. The result is an input-indexed
array of `completed`, `failed`, `unknown` or `skipped` outcomes, each with
`effect` and optional `value`/`error`. Nonzero exits are failed outcomes with
their actual result in `error.partial`. Other commands continue. A canceled
batch exposes a frozen `err.partial.outcomes` receipt; it preserves completed
results and distinguishes started work from work never sent.

All commands and process options are validated and copied before dispatch.
One submission accepts at most 1,024 commands, 4,096 total arguments and
16 MiB of input. NUL is rejected in argv and environment entries; raw stdin
can contain it. Never retry mutations automatically, especially after an
unknown effect. Canceling a client does not prove daemon work stopped.

Process options include `stdin`, `cwd`, explicit `env` entries, `timeout`,
monotonic `deadline`, `max_output_bytes` (default 1 MiB), `drain_timeout`
(250 ms), and `kill_timeout` (100 ms). Timeout/deadline apply to the client
operation; pinned endpoint evidence uses a separate bounded check. Output
limits and runtime byte admission remain distinct. Excess batch output is
reported with byte counts and truncation metadata; it is not silently kept.

The raw API is an escape hatch. Named domain operations, owned command
completion and observation APIs are still under development. A successful
`send-keys` process does not report the exit of a pane application.
