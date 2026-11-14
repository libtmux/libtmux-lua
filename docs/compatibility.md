# Compatibility targets

This release line supports tmux 3.3a and newer.

- A push and a pull request run the integration suite on the
  oldest and newest released tmux (3.3a and 3.8). A release runs it on every
  version in the table below.
- A release outside the table is expected to work but is untested, and option
  operations refuse it ([minimum release](#minimum-tmux-release)).
- A source declaration, a successful import or a sibling port's result does
  not establish live compatibility.
- Features that need more than the minimum are under
  [optional features](#optional-features), and in
  [`capabilities.json`](../capabilities.json).

| Component | Versions CI covers |
| --- | --- |
| PUC Lua | 5.1.5, 5.2.4, 5.3.6, 5.4.9, 5.5.1 |
| LuaJIT | v2.1 at c6ffc141a8762b41703f9287d63d93622a13dd8f |
| Standalone adapter | luv 1.52.1-0 built for each runtime ABI |
| Neovim | 0.10.0, 0.12.5 |
| tmux | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 |
| Platforms | Ubuntu 24.04 x86_64 in CI; WSL2 checked locally |

- Pure-core tests run once per runtime and platform. Standalone and embedded
  live tests run on the floor and current tmux for each runtime or host. The
  full tmux sweep uses PUC Lua 5.5.1 and current Neovim.
- Floor and current combinations also run interoperability tests. A client and
  daemon of different versions report protocol failures; the library never
  infers daemon capabilities from the client executable.
- macOS and native Windows are outside the matrix. Results from builds outside
  it, such as unreleased builds, are diagnostic only. Neovim's LuaJIT results
  do not prove stock PUC Lua 5.1 yield behavior; a Neovim built on PUC Lua is a
  separate host gate.

## Minimum tmux release

The minimum is tmux 3.3a, compared as a whole release: 3.3 is below it.

- A development build (`next-X.Y`) or release candidate (`X.Y-rc`,
  `X.Y-rcN`) ranks just below the release it names. It is accepted when it
  ranks at or above 3.3a: `next-3.9` clears the minimum, while `next-3.3` and a
  candidate of 3.3 do not.
- A candidate with a patch letter, such as `X.Ya-rcN`, names no release and is
  refused.
- Clearing the minimum does not list a release: code that keys on exact
  releases refuses versions it does not list, such as 3.9 or a candidate of it.
- Release candidates are not supported. A feature can require one only until
  its release ships. See
  [Release candidates](https://libtmux.org/en/tmux/guides/tmux-support/#release-candidates).

How the check works:

- The library reads the connected daemon's own `#{version}`, never the client
  executable's `-V`, so a newer client cannot pass for an older daemon.
- The endpoint reads the daemon's version, pid and start time once, when it
  binds, with `run-shell -C`, which fires no `after-*` or `command-error` hook.
  Each command group then starts with a fence on the cached pid, start time and
  release, so a command costs no probe.
- A daemon that changed after the check raises `stale_generation`, none of the
  group's commands run, and the cache is dropped. A daemon that is gone raises
  the same error.
- The endpoint binds only to a running server and always passes `-N`, so no
  client starts a daemon.

A daemon below the minimum raises `unsupported_version` when connecting, with
`effect = "not_sent"`. So does a report that names no release, such as bare
`master`; its message says so instead of calling the version too old.

- tmux before 3.2 has neither `run-shell -C` nor the client's `-N`. Its server
  answers the probe with a usage error (3.1) or is turned away by a newer
  client (3.0), and an executable that old rejects `-N`. All three raise
  `unsupported_version`.
- The message gives the remedy: upgrade tmux to 3.3a or newer and restart the
  server, or install the previous libtmux release. The last release that
  supports tmux 3.2a is 0.1.0alpha1-1; 0.1.0alpha2-1 raised the minimum.

The table includes 3.7d and 3.8, the current stable release.

- 3.7d shares 3.7c's option table and decoders.
- 3.8 changes the option table, the layout export (JSON for non-control
  clients) and paste sanitization. The catalog and layout check cover those.
- `next-3.9` is a development build. Its row describes the upstream master
  commit pinned in the option catalog, so a later master build can differ.

The full CI run builds all three. It also has tmux 3.0a, 3.1c, 3.2a and the
unpatched 3.3 as refusal lanes. They assert the refusal and that no requested
operation ran, and do not run the integration suite. The 3.0a and 3.1c lanes
also run the check with a 3.3a client against the old daemon, which covers the
3.1 usage error and the 3.0 "too old for client" answer.

## Optional features

The 3.3a minimum covers subprocess commands, typed operations, snapshots and
polling captures. Each feature below names its own release requirement. A
refusal has a test that fails when the guard is removed.

| Feature | tmux | State |
| --- | --- | --- |
| Commands, typed operations, snapshots, captures | 3.3a to 3.8, 3.7d and the pinned next-3.9 build | Works where the CI integration suite passes at that release |
| Control observation (`observe`, watches, subscriptions) | below 3.7 | Refused with `unsupported` before any attachment |
| Control observation | 3.7 to 3.8 | Idle attachment, watches and subscriptions work; concurrent acquisition from several processes is not tested |
| Waiting for pane text (`Pane:wait_for_text`) | 3.3a to 3.8 | Works where the CI integration suite passes at that release; it polls and never uses control mode |
| Named buffer deletion (typed and literal) | below 3.4 | Refused |
| Named paste with `delete_after` | 3.3a and later | Works: tmux looks the buffer up exactly |
| `run-shell` output | 3.3a to 3.4 | Raw client output only: tmux sends job output to pane view mode, so nothing is captured; later releases write it to the client |
| Custom layout strings | below 3.4 | Works with validation: a checksum header is required |
| JSON layout strings | 3.8 and later | Accepted |
| JSON layout strings | below 3.8 | Refused before dispatch with `invalid_layout` |
| Literal `select-layout` with a JSON layout | below 3.8 | Refused before dispatch with `unsupported` |
| Percentage splits | 3.4 | Typed splits encode `-l N%`; literal `-p` is refused |
| Window breaks | exactly 3.7 | Typed `break_out` works, with a rename repair; literal `break-pane` is refused |
| Session and window names with `:` or `.` | exactly 3.7 | Refused before dispatch |
| Development builds | `next-3.9` | Works only for the master commit pinned in the option catalog; other development builds and `X.Y-rcN` candidates have no option table, so option operations refuse them |

Named buffer deletion requires tmux 3.4 or later. The typed API refuses older
releases because a missing target can delete another buffer; see
[buffers](buffers.md).

Checks on macOS do not run in CI, so macOS is untested. Checks run locally under
WSL2 do not replace the Linux CI jobs. The
[CI workflow](../.github/workflows/ci.yml) runs the Linux unit runtimes, the
floor and current outer gates and the integration sweep; its
[setup](../.github/CONTRIBUTING.md#github-actions) uses the same local gate
commands. A run covers only the revision it tested.

Sources: [Lua's version history](https://www.lua.org/versions.html),
[LuaJIT's release policy](https://luajit.org/status.html), the
[luv release](https://github.com/luvit/luv/releases/tag/1.52.1-0),
[Neovim's Lua contract](https://neovim.io/doc/user/lua/#lua-compat) and
[tmux releases](https://github.com/tmux/tmux/releases).
