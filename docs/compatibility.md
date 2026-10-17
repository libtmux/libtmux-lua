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
matrix. Local tmux 3.7d and 3.8-rc results are diagnostic evidence and cannot
replace released-version checks. Neovim's LuaJIT results do not prove stock
PUC Lua 5.1 yield behavior. A Neovim build using PUC Lua is a separate host gate.

## Minimum tmux release

The supported minimum is tmux 3.3a, compared as a complete release: 3.3 is
below it. The library checks the connected daemon's own `#{version}`, never
the client executable's `-V`, so a newer client cannot pass for an older daemon.
A development build (`next-X.Y`) or release candidate (`X.Y-rcN`) ranks just
below the release it names: `next-3.9` and `3.8-rc2` clear the minimum, while
`next-3.3a` does not. Reports that name no release, such as bare `master`, are
refused. Clearing the minimum does not qualify a release: subsystems that key on exact
releases refuse versions they do not list, such as 3.9 or `3.8-rc2`.

The listed releases include 3.7d, the current stable release, and 3.8. 3.7d
shares 3.7c's option table and decoders. 3.8 changes the option table, the
layout export (JSON for non-control clients) and paste sanitization, and the
catalog and layout check cover those. `next-3.9` is a development build: its
row describes the upstream master commit pinned in the option catalog, so a
later master build can differ. CI builds all three.

The pinned endpoint reads the daemon's version, pid and start time once, when
it binds, with `run-shell -C`, which fires no `after-*` or `command-error`
hook. It caches that version and starts each dispatched command group with a
fence on the cached pid, start time and release, so a command costs no probe.
A daemon that changed after the check raises `stale_generation`, none of the
group's commands run, and the cache is dropped; a daemon that is gone raises
the same error because `-N` stops a client from starting another. A daemon below the
minimum raises `unsupported_version` when connecting. The endpoint only binds
to an existing socket and always passes `-N`, so no client binary starts a
daemon.

CI runs tmux 3.2a and the unpatched 3.3 as refusal lanes. They assert the
refusal and that no command ran; they do not run the integration suite.

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
