# Compatibility targets

The Lua port is under development. The following versions define required
acceptance tests; they are not a published support promise. A source declaration,
successful import, or sibling-port result does not establish live compatibility.

| Component | Required versions |
| --- | --- |
| PUC Lua | 5.1.5, 5.2.4, 5.3.6, 5.4.9, 5.5.1 |
| LuaJIT | v2.1 at c6ffc141a8762b41703f9287d63d93622a13dd8f |
| Standalone adapter | luv 1.52.1-0 built for each runtime ABI |
| Neovim | 0.10.0, 0.10.4, 0.11.7, 0.12.5 |
| tmux | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 |
| Platforms | Linux x86_64, macOS arm64; WSL2 recorded separately |

Pure-core tests run once per runtime/platform. Standalone and embedded live
tests cover floor/current tmux for each runtime or host. The full tmux sweep
uses PUC Lua 5.5.1 and current Neovim. Consumer imports and pure validation cover
each runtime; floor/current combinations also run interoperability and workspace
failure tests. Client/daemon version mismatches must report protocol failures
truthfully instead of inferring daemon capabilities from the client executable.

macOS x86_64 and native Windows transport are outside the initial platform
matrix. Results from builds outside the matrix, such as release candidates,
are diagnostic evidence and cannot replace released-version checks. Neovim's
LuaJIT results do not prove stock PUC Lua 5.1 yield behavior. A Neovim build
using PUC Lua is a separate host gate.

## Minimum tmux release

The supported minimum is tmux 3.3a, compared as a complete release: 3.3 is
below it. A development build (`next-X.Y`) or release candidate (`X.Y-rc`,
`X.Y-rcN`) ranks just below the release it names and is accepted when it
ranks at or above 3.3a: `next-3.9` and `3.8-rc2` clear the minimum, while
`next-3.3` and `3.3-rc` do not. Clearing the minimum does not qualify a
release: subsystems that key on exact releases refuse versions they do not
list, such as 3.9 or `3.8-rc2`.

The library checks the connected daemon's own `#{version}`, never the client
executable's `-V`, so a newer client cannot pass for an older daemon. The
pinned endpoint reads the daemon's version, pid and start time once, when it
binds, with `run-shell -C`, which fires no `after-*` or `command-error` hook.
Each dispatched command group then starts with a fence on the cached pid,
start time and release, so a command costs no probe. A daemon that changed
after the check raises `stale_generation`, none of the group's commands run
and the cache is dropped; a daemon that is gone raises the same error. The
endpoint only binds to an existing socket and always passes `-N`, so no
client binary starts a daemon.

A daemon below the minimum raises `unsupported_version` when connecting, with
`effect` set to `not_sent`. So does a report that names no release, such as
bare `master`; its message says so instead of calling the version too old.
tmux before 3.2 has neither `run-shell -C` nor the client's `-N`: its server
answers the probe with a usage error (3.1) or is turned away by a newer
client (3.0), and an executable that old rejects `-N`. All three raise
`unsupported_version` too. The message states the remedy: upgrade tmux to
3.3a or newer and restart the server, or install the previous libtmux
release (0.1.0alpha2-1, which supports 3.2a).

The listed releases include 3.7d, the current stable release, and 3.8. 3.7d
shares 3.7c's option table and decoders. 3.8 changes the option table, the
layout export (JSON for non-control clients) and paste sanitization, and the
catalog and layout check cover those. `next-3.9` is a development build: its
row describes the upstream master commit pinned in the option catalog, so a
later master build can differ. CI builds all three.

CI runs tmux 3.0a, 3.1c, 3.2a and the unpatched 3.3 as refusal lanes. They
assert the refusal and that no command ran; they do not run the integration
suite. The 3.0a and 3.1c lanes also run the check with a 3.3a client against
the old daemon, which covers the 3.1 usage error and the 3.0 "too old for
client" answer.

## Optional features

The 3.3a minimum covers subprocess commands, typed operations, snapshots and
polling captures. Each feature below names its own release requirement and
its state in the stated evidence. A refusal is checked by a test that fails
when the guard is removed; a feature without such a test is unverified.

| Feature | tmux | State |
| --- | --- | --- |
| Commands, typed operations, snapshots, captures | 3.3a to 3.8, 3.7d and the pinned next-3.9 build | Qualified where the CI integration suite passes at that release |
| Control observation (`observe`, watches, subscriptions) | below 3.7 | Non-operative: refused with `unsupported` before any attachment |
| Control observation | 3.7 to 3.8 | Qualified for idle attachment, watches and subscriptions; concurrent acquisition from several processes is unverified |
| Named buffer deletion (typed and literal) | below 3.4 | Non-operative: refused |
| Named paste with `delete_after` | 3.3a and later | Qualified: tmux looks the buffer up exactly |
| `run-shell` output | 3.3a to 3.4 | Raw client output only: tmux sends job output to pane view mode, so nothing is captured; later releases write it to the client |
| Custom layout strings | below 3.4 | Operative with validation: a checksum header is required |
| Percentage splits | 3.4 | Typed splits encode `-l N%`; literal `-p` is refused |
| Window breaks | exactly 3.7 | Typed `break_out` is operative with a rename repair; literal `break-pane` is refused |
| Session and window names with `:` or `.` | exactly 3.7 | Refused before dispatch |
| Development builds | `next-3.9` | Qualified only for the master commit pinned in the option catalog; other development builds and `-rc` builds are supported but their option table is unlisted, so option operations refuse them |

Named buffer deletion requires tmux 3.4 or later. The typed API refuses older
releases because a missing target can delete another buffer. The older-release
deletion parity requirement remains open; see [buffers](buffers.md).

Exact operating-system images, binary hashes, compiler and module ABI identities
belong with each result. Missing and skipped cells remain unverified. No complete
product compatibility cell has passed yet.

Current local implementation evidence comes from Ubuntu 24.04 under WSL2
on x86_64. Record it in the WSL2 lane; it does not close the native Linux or
macOS gates. Selected PUC, LuaJIT, Neovim and tmux foundation tests have passed
there while the complete product is still being implemented.

The [CI workflow](../.github/workflows/ci.yml) covers Linux unit runtimes,
floor/current outer gates and the released-tmux integration sweep. Its
[setup and coverage](../.github/CONTRIBUTING.md#github-actions) use the same
local gate commands. A passing run establishes those implemented checks at
its tested revision; macOS, additional host/runtime combinations and
unfinished product requirements remain open.

Version evidence comes from [Lua's version history](https://www.lua.org/versions.html),
[LuaJIT's release policy](https://luajit.org/status.html), the
[luv release](https://github.com/luvit/luv/releases/tag/1.52.1-0),
[Neovim's Lua contract](https://neovim.io/doc/user/lua/#lua-compat), and
[tmux releases](https://github.com/tmux/tmux/releases).
