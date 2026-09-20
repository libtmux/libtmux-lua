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
| tmux | 3.2a, 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c |
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
