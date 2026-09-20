# Execute tmux commands

After [connecting](snapshots.md), `server:command(argv, options)` submits
literal tmux arguments and returns a Request. It preserves raw stdout/stderr
bytes, exit code and signal, and waits for the owned client and its pipes to
retire. A completed nonzero exit is returned as result data. Spawn, timeout,
output-limit and incomplete-drain failures return `nil, err`.

No shell parses argv. tmux still parses its own command syntax; the library
protects literal separator arguments. A tmux command that explicitly accepts
shell text, such as `run-shell`, retains that command's shell semantics.

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
job output to pane view mode on tmux 3.3–3.4; tmux 3.2a and 3.5 onward
write it to the waiting client's stdout. An explicit `-t` pane target
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
