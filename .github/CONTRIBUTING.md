# Contributing

This repository contains the Lua query, transport and package foundation for
libtmux. Domain coverage and consumer features remain under development.
Complete product compatibility remains unverified.

[AGENTS.md](../AGENTS.md) governs scope and change discipline.
[WRITING.md](WRITING.md) governs prose and commit messages.

## Environment

[.tool-versions](../.tool-versions) pins the development interpreter. The pin
does not define a supported Lua range or promise LuaJIT compatibility.

Install the pinned interpreter with mise:

```console
$ mise install
```

Check the selected interpreter:

```console
$ mise exec -- lua -v
```

Development scripts require Python 3.12 or newer; the development pin supplies
3.14.6. LuaRocks 3.13.0, a C compiler, make, CMake, StyLua 2.4.0 and
actionlint 1.7.12 are build prerequisites. Bootstrap runs outside all test
loops and may use the network.

The [example launcher](../examples/api/run.sh) also needs `perl` on `PATH`, to
confirm over a socket connection that tmux stopped. The Ubuntu 24.04 CI image
and macOS include it. The launcher exits before it starts tmux when it is
missing.

Build the floor interpreter and the Lua 5.4.9 lint-tool interpreter:

```console
$ mise exec -- python scripts/bootstrap_runtimes.py 5.1.5 5.4.9
```

Install unit-test and standalone runtime dependencies for the development Lua:

```console
$ mise exec -- python scripts/bootstrap.py dev live
```

Install lint dependencies under the separate tool interpreter. Luacheck 1.2.0
assigns to a loop variable, which Lua 5.5 rejects; this tool constraint does
not change the library's runtime targets.

```console
$ mise exec -- python scripts/bootstrap.py lint \
    --lua=.cache/toolchains/lua-5.4.9/bin/lua
```

Install native prerequisites and LuaLS 3.19.1 into the ignored local cache:

```console
$ mise exec -- python scripts/bootstrap_native.py yaml luals
```

Install consumer codecs. LibYAML 0.2.5 is built statically in that cache; the
external package check verifies the resulting native binding actually loads.

```console
$ mise exec -- python scripts/bootstrap.py consumers \
    --yaml-dir=.cache/libyaml
```

Bootstrap additional interpreters' unit dependencies with the same `--lua`
option. C modules must be built separately for each interpreter ABI.

Build the accepted standalone LuaJIT revision:

```console
$ mise exec -- python scripts/bootstrap_runtimes.py luajit
```

Install its independent unit and live dependencies:

```console
$ mise exec -- python scripts/bootstrap.py dev live \
    --lua=.cache/toolchains/luajit-2.1/bin/luajit
```

The scripts keep LuaJIT and PUC Lua 5.1 rocks in separate cache trees, even
though both report the Lua 5.1 ABI. LuaJIT uses the same absolute prefix during
build and installation, following its [installation guide](https://luajit.org/install.html).

Install the accepted Neovim hosts into separate local cache directories:

```console
$ mise exec -- python scripts/bootstrap_hosts.py 0.10.0 0.10.4 0.11.7 0.12.5
```

The host bootstrap supports Linux x86_64. It verifies pinned official archive
hashes, each executable and its embedded runtime. Existing installations stay
unchanged. `--check` verifies the cached hosts without network access.

## Validation

The runner discovers unit suites and reports whole-process child timings.
Time the invoking command too when recording gate evidence. Test gates are
offline and fail on missing prerequisites; they never install dependencies.

Run a focused inner suite:

```console
$ mise exec -- python scripts/check.py unit query
```

Run unit suites, Lua51 formatting, lint, generated-field drift, links, README
examples and whitespace checks:

```console
$ mise exec -- python scripts/check.py mid
```

Each README must open with Quick start and close with What it leaves out and
Support and status. Keep each paragraph and list item to about three lines.
Mark every Lua block with the example program it quotes: `<!-- example: path -->`
for a whole file, or `<!-- excerpt: path -->` for consecutive lines of it.

Run the current outer gates: mid checks, owned-tmux integration, independent
artifact builds/imports, LuaLS diagnostics and actual editor completion:

```console
$ mise exec -- python scripts/check.py outer
```

Integration includes real luv and Neovim loop ownership, process cancellation,
post-exit pipe draining and metadata byte round-trips. These use the selected
Lua interpreter and its own luv ABI; Neovim uses its embedded runtime.

The package gate builds development rocks and installs each into its own
temporary prefix. Consumer prerequisites are packed from the bootstrap cache;
network servers and ambient Lua paths are disabled. Imports and the native
query example execute outside the checkout. Missing dependencies fail locally.
All three packages use the [MIT license](../LICENSE). The gate verifies each
installed rockspec and license against the source files. No release artifacts
are published.

The same gate checks the core release candidate in [release.json](../release.json).
It packs the committed release rockspec through an isolated local Git source,
installs the resulting source rock outside the checkout, and runs the pure
query and live snapshot examples. The public source tag is checked only by
the publication workflow, after that tag exists.

Select a specific tmux binary through `TMUX_BIN`. Run floor/current versions
separately and record their actual identities. The fixture runner handles
SIGINT/SIGTERM by unwinding owned resources before exit. Linux forced cleanup
uses owned pidfds; macOS cleanup remains an explicit unverified gate.

Select the floor Lua and a cached Neovim explicitly:

```console
$ mise exec -- python scripts/check.py integration \
    --lua=.cache/toolchains/lua-5.1.5/bin/lua \
    --nvim=.cache/toolchains/nvim-0.10.0/bin/nvim
```

Set `TMUX_BIN` to the intended floor or current executable for each run.
Local WSL2 checks are recorded separately from hosted Linux and macOS.
The official Neovim 0.10.0 archive reports
`prerelease="dev"` through `vim.version()` despite its release CLI version;
the bootstrap records both values and verifies the exact artifact checksum.

Compatibility sweeps, live examples, generated reference checks and benchmarks
will extend these commands as their implementations land. The present outer
gate does not establish the full [compatibility matrix](../docs/compatibility.md).

The [field catalog](../data/tmux-fields.json) generates Lua schemas, LuaLS
annotations and the [field reference](../docs/fields.md). Regenerate after
reviewing a catalog change; the mid gate checks drift without network access:

```console
$ mise exec -- python scripts/generate_fields.py
```

The [option catalog](../data/tmux-options.json) generates private release
metadata and the [option reference](../docs/options-reference.md). Normal
generation and drift checks are offline:

```console
$ mise exec -- python scripts/generate_options.py
```

Check whitespace in unstaged changes:

```console
$ git diff --check
```

Check whitespace in staged changes:

```console
$ git diff --cached --check
```

Report which checks ran and which remain unavailable. Missing or skipped
compatibility, examples and CI evidence remain open gates.

### GitHub Actions

[CI](workflows/ci.yml) runs on pull requests, pushes to `master` and manual
dispatch. A pull request and a push test only the oldest and newest released
tmux (3.3a and 3.8). The full scope covers the whole table, and runs for a
release ([Publish](workflows/publish.yml) asks for it) and for a dispatch with
`scope=full`. Ubuntu 24.04 jobs run the existing offline gates after a separate
dependency bootstrap:

- Unit suites on every accepted PUC Lua version and standalone LuaJIT.
- Full outer checks at Lua/Neovim floor and current versions, including format,
  lint, generated files, docs, installed rocks and LuaLS completion. The floor
  job runs on the oldest released tmux. The current job runs on the newest on a
  push and a pull request, and on 3.7c in the full scope, where
  `data/ci-matrix.json` pins it.
- The full integration suite, using current Lua and Neovim, on the oldest and
  newest released tmux. The full scope runs it on every accepted tmux release
  from 3.3a, which includes 3.7d and the pinned `next-3.9` development build.
  Those two have no tag, so they build from a branch commit.
- In the full scope, a refusal lane for each release below the minimum (3.0a,
  3.1c, 3.2a and the unpatched 3.3). It runs only the version check tests,
  which assert the refusal and that no requested operation reached the daemon.
  The 3.0a and 3.1c lanes use that release as the client, then repeat the check
  with a 3.3a client in front of the old daemon (`TMUX_CLIENT_BIN`), which
  covers the 3.1 usage error and the 3.0 "too old for client" answer. That run
  must refuse in under half a second (`LIBTMUX_REFUSAL_MAX_MS`), because a
  pre-3.2 daemon holds the client's output open and the probe timeout is
  750 ms.

Jobs retain tool identities, gate output and build diagnostics. Actions use
pinned commits and read-only repository permissions. Setup failures fail the
job; gates do not install missing dependencies. The job deadline includes
bootstrap and does not replace the test-loop budgets below.

CI builds tmux at the commit recorded in the option catalog (or, for a refused
release, the pinned tag), checks the
reported version and records the binary hash. To reproduce that setup:

```console
$ mise exec -- python scripts/bootstrap_native.py tmux \
    --tmux-version=3.7c
```

The build requires Autoconf, Automake, a C compiler, make, pkg-config, Bison,
libevent and ncurses development headers. Select its result through
`TMUX_BIN=.cache/toolchains/tmux-3.7c/bin/tmux` when running a gate.
macOS, remaining runtime/host combinations and unfinished product gates stay
open in the [compatibility matrix](../docs/compatibility.md).

### Running CI against any tmux

A `plan` job runs [ci_plan.py](../scripts/ci_plan.py) on
[the option catalog](../data/tmux-options.json) and
[ci-matrix.json](../data/ci-matrix.json) and decides the jobs, so the workflow
lists no version. The catalog's releases
are the table, and the first and last released entries are the edges. A
development build is never an edge. The `required` job passes when the plan and
the matrix succeeded, and is the one check to require.

Run the workflow on any branch, against any tmux version, tag, branch or full
commit of github.com/tmux/tmux. Put the comma-separated list in `tmux-ref`, with
`scope=custom`:

```console
$ gh workflow run ci.yml \
    --ref my-branch \
    -f scope=custom \
    -f tmux-ref=3.6b,master
```

A version that the table pins is built at its pinned revision. Any other ref is
resolved to a commit and built from source by
`scripts/bootstrap_native.py tmux --tmux-ref`, in a directory named for the
commit. Each ref runs the integration suite, or the refusal check for a release
below the minimum.

Name other Lua runtimes or Neovim versions from `data/ci-matrix.json` with
`lua` and `nvim`; they apply to the tmux jobs and multiply with the refs. The
`os` input picks the Ubuntu image. The `tmate` input opens a
[tmate](https://github.com/mxschmitt/action-tmate) session on exactly one job,
before the tests or after a failure. The session admits only the GitHub account
that dispatched the run and ends after 30 minutes. The plan refuses it when the
run has more than one job:

```console
$ gh workflow run ci.yml \
    --ref my-branch \
    -f scope=custom \
    -f tmux-ref=3.6b \
    -f lua=luajit \
    -f tmate=on-failure
```

Run every job a release runs, without tagging:

```console
$ gh workflow run ci.yml \
    --ref my-branch \
    -f scope=full
```

Dispatch runs do not cancel one another or the push run of the same branch.

### Test loops

Measure the whole command, including startup and setup. Libraries should aim
for the target times below.

| Loop | Budget | Target | Scope |
| --- | --- | --- | --- |
| Inner | < 5 seconds | < 2 seconds | Tests for changed code, after each edit. |
| Mid | < 30 seconds | < 10 seconds | Unit tests, lint, generated-file checks. |
| Outer | < 5 minutes | < 60 seconds | Builds, type checks, and full matrices. |

Run the mid loop after each change and before handoff, and the outer loop
before a commit or pull request.

- Keep network access, installs, production builds, browser launches, sleeps,
  and broad corpus scans out of the inner and mid loops.
- Treat a timeout or wait over one second as a structural bug. Use events or
  subscriptions and fix the cause instead of adding sleeps.
- Tag slow tests with a one-line reason and run them in the outer loop.
- If a loop exceeds its budget, remove redundant setup and slow paths before
  adding more tests. Do not raise the budget.
- Keep benchmarks separate: under ten minutes per run and one hour per sweep.

## tmux isolation

Any test or probe that starts tmux must use an explicit socket in a unique
temporary directory named for `libtmux-lua`. Clear inherited `TMUX` and
`TMUX_PANE` values in the child environment. Never use the default server of
the developer's `TMUX_TMPDIR`; only a test of how a connection chooses its
server starts one, and only on the sandbox's own default socket, below.

Clean up only the server and files owned by that run, including on failure.
Do not stop servers or remove directories belonging to another port or to
the developer's sessions. Use real tmux to verify tmux behavior once the
library and its integration tests exist.

A tmux command that names no socket goes to the server an inherited `TMUX`
names, and otherwise to the default socket under `TMUX_TMPDIR`. The
[test sandbox](../tests/support/sandbox.py) removes `TMUX`, `TMUX_PANE` and
every `LIBTMUX_SOCKET*` variable and sets `TMUX_TMPDIR` to an owner-only
`libtmux-lua-sb-` directory, so a test that forgets `-S` finds nothing.

`scripts/check.py`, `scripts/package.py`, `tests/run_integration.py`, the tmux
fixture and the `tests.integration` package enter the sandbox, and their
children join it. Importing the package covers a direct `python3 -m unittest`
run of one of its modules; discovering a module by path does not, and the canary
refuses there. The launcher `examples/api/run.sh` does the same for the programs
it runs, in a directory under `TMPDIR`, or under `/tmp` when `TMPDIR` leaves no
room for the default socket path. A new entry point that starts tmux must enter
the sandbox or be started by one that did.

Lua cannot change its environment, so `tests/run.lua` only checks: it exits
with status 2 unless a parent made the sandbox. Run unit suites through
`scripts/check.py`.

The directory goes under `TMPDIR`, or under `/tmp` when `TMPDIR` is too long for
a socket path, so keep `TMPDIR` short. The fixture's own directories stay under
`/tmp`. At exit, the process that made the sandbox fails the run if a socket is
left anywhere in the sandbox, even when every test passed, whether tmux chose it
for a command that named none or a test named it with `-S`. It stops each server
with `tmux -S <socket> kill-server`, then connects to confirm nothing answers. A
server that still answers keeps the directory, which the failure names. The
launcher does the same for its own directory, confirming each stop with a
connection to the socket from `perl` and not with a tmux client. Refusals and
failures name variables, sockets and directories, never the values of
environment variables.

The [canary](../tests/integration/test_sandbox.py) shows that a client naming no
socket looks only under the sandbox. Three more tests check the guard without
tmux, using a [recording stand-in](../tests/support/recorder.py) that writes
arguments and variable names, never values: the
[sandbox](../tests/tooling/test_sandbox.py) test in the mid loop, and the
[canary runner](../tests/integration/test_canary_runner.py) and
[launcher](../tests/integration/test_launcher.py) tests with the integration
suite, since the tooling tests share a five-second limit in `scripts/check.py`.
Prove a change to the guard that way before running a suite.

`Runtime:connect` with no `socket_path` reads `LIBTMUX_SOCKET_PATH`, then
`LIBTMUX_SOCKET`, and otherwise leaves the server to tmux, so a program run by
hand with neither set reaches the server you work in. The sandbox clears both
variables, and tests that connect name their own socket or set a variable in a
child process they start. tmux leaves its socket file behind when a server
exits, and the tree check counts it, so a test that starts a server on the
default socket stops it, waits for it to exit and removes the file, as
[the default-socket test](../tests/integration/test_socket_default.py) does.

To run a program by hand against a server of your own, keep a `.env` that names
its socket. `.gitignore` keeps it out of commits, and the rockspecs install
only the modules they list. Write the file:

```console
$ printf 'LIBTMUX_SOCKET_PATH=%s\n' /tmp/libtmux-lua-dev.sock > .env
```

The library never starts a server, so start one on that socket first:

```console
$ tmux -S /tmp/libtmux-lua-dev.sock -f /dev/null new-session -d
```

Load the file into the shell before running the program:

```console
$ set -a && . ./.env && set +a
```

Stop the server when you are done. tmux leaves its socket file behind, and a
connection to it reports `uncertain_generation`:

```console
$ tmux -S /tmp/libtmux-lua-dev.sock kill-server
```

## Pull requests

Keep one subject per pull request and one logical change per commit. Describe
the resulting behavior, why it matters, and the checks actually run. Include
elapsed time and any unverified compatibility claims. Update documentation
when observable behavior changes.

## Releases

Only `libtmux` is released. `libtmux-mcp` and `libtmux-workspace` remain
unpublished development scaffolds; their independent package checks continue
to run. Releases are numbered `0.1.N`: `0.1.0`, then `0.1.1`, `0.1.2` and so
on, with no alpha or other prerelease tag unless the maintainer asks for one.
The API is not settled, so a release may change or remove exported
identifiers; the changelog marks each break. The release covers the
implemented core, with the limits recorded in the
[compatibility matrix](../docs/compatibility.md).

### Prepare a version

Add user-visible changes under `Unreleased` in the changelog of the rock they
change: [CHANGES.md](../CHANGES.md) for `libtmux` and for changes that span
rocks, [packages/mcp/CHANGELOG.md](../packages/mcp/CHANGELOG.md) for
`libtmux-mcp` and
[packages/workspace/CHANGELOG.md](../packages/workspace/CHANGELOG.md) for
`libtmux-workspace`. Then run this from the repository root:

```console
$ mise exec -- python scripts/release.py prepare 0.1.1-1
```

The command uses [LuaRocks new_version](https://github.com/luarocks/luarocks/blob/v3.13.0/src/luarocks/cmd/new_version.lua)
to generate a versioned rockspec from the development rockspec. It updates
`release.json`, `libtmux._VERSION` and the changelog heading. It does not commit,
tag, push or publish. Existing versioned rockspecs stay in the repository.
Date the prepared changelog heading when cutting the release; leave
`Unreleased` in place for later changes.

Check those files without changing them:

```console
$ mise exec -- python scripts/release.py prepare --check
```

Check that every rock keeps its changelog, opening with its own name and
holding an `## Unreleased` section, and that each rockspec other than the
core's installs it. The generated gate and the publication guards run the
same check:

```console
$ mise exec -- python scripts/release.py changelogs
```

`0.1.N` is the source/runtime version; `-R` is the rockspec revision.
Source changes advance the source version, for example from `0.1.0-1` to
`0.1.1-1`. Packaging-only fixes advance the revision to `0.1.0-2`, keeping the
source tag `v0.1.0`. These follow the
[LuaRocks version rules](https://github.com/luarocks/luarocks/blob/main/docs/rockspec_format.md).

Run the timed mid and outer gates documented above. To retain the candidate
and its SHA256 checksums, choose an empty output directory:

```console
$ mise exec -- python scripts/package.py \
    --release \
    --output dist
```

This checks the actual source rock and records the checkout commit, dirty
state and source method in `candidate.json`. Local candidates are explicitly
marked `local-fixture`; publication refuses them. PR CI retains a
`release-candidate` artifact with the same checks, without registry secrets.

### Configure publishing

The publisher is [tony](https://luarocks.org/modules/tony). Before the first
publication, confirm that `libtmux` is available in the root manifest. The
initial public search found no matching module; that is not a reservation.
Set up a GitHub environment named `luarocks`, restrict it to the intended
release tags, require a
maintainer reviewer, and store that account's key as `LUAROCKS_API_KEY` there.
Do not put the key in files, command examples or PR jobs.

LuaRocks documents [API-key uploads](https://luarocks.org/docs/api), not an
OIDC exchange. The workflow uses a temporary CLI key only in the upload step.
If the account requires a two-factor token for uploads, resolve the supported
CLI/account configuration before releasing; the workflow does not store a
TOTP seed or bypass that requirement. Verify native OIDC support again before
changing this authentication model.

[GitHub attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
record artifact provenance. Their OIDC permissions do not authenticate an
upload to LuaRocks. `Publish` uses pinned actions and separate job permissions.
A manual `Publish` run only validates; it never uploads.

### Publish after the preparation PR merges

Start from clean, updated `master`, with its CI passing. Each release
uses the lightweight source tag `v0.1.N`, such as `v0.1.1`; create it at the
reviewed release commit:

```console
$ git tag v0.1.1
```

Push that tag to the public repository to start [Publish](workflows/publish.yml):

```console
$ git push origin refs/tags/v0.1.1
```

The workflow reruns CI at that commit with `scope=full`, so every accepted
tmux release and each refusal lane passes first. It validates the public
source tag and packs its source rock. It checks the installed artifact, then
verifies its checksums again in the protected upload job. That job uploads the
same rockspec and source rock to LuaRocks, then creates a GitHub release with
generated notes, artifacts, checksums and provenance. A version with an
alpha, beta or rc suffix would be marked as a prerelease; `0.1.N` releases
are not. No package is rebuilt during upload.

For packaging revisions, use a separate release tag such as
`rocks/0.1.1-2` at the reviewed packaging commit. Keep the original source
tag unchanged and the Lua sources identical to it. The publishing guard
checks both tag identities. If Lua code changed, prepare a new source version.

### Verify and recover

After publication, install the exact version in a fresh tree:

```console
$ luarocks install \
    --tree .cache/release-install \
    libtmux 0.1.1-1
```

Download the release assets and verify their checksums:

```console
$ sha256sum --check SHA256SUMS
```

Verify the source rock's GitHub provenance:

```console
$ gh attestation verify libtmux-0.1.1-1.src.rock \
    --repo libtmux/libtmux-lua
```

LuaRocks rejects a duplicate package version. Never use `--force` or move a
published source tag. If the rockspec uploaded but its source rock did not,
inspect the registry state and the retained artifact before doing anything
else. Recover through LuaRocks' documented `upload_rock` endpoint using the
unchanged validated artifact and existing version ID, or publish a corrected
rockspec revision through review. Do not rerun the entire upload with force.

If LuaRocks succeeded but creating the GitHub release or attaching assets
failed, verify the registry files, create the release if needed, and attach
the retained assets; do not re-upload the package. The native uploader's
duplicate rejection is intentional.

## Repository metadata

[repository.json](repository.json) records the desired visibility, default
branch, description, topics, and issue labels for both GitHub repositories.
GitHub does not apply this file automatically; apply metadata changes through
the GitHub CLI or API and verify both repositories afterward.

- `origin`: [libtmux/libtmux-lua](https://github.com/libtmux/libtmux-lua).
- `tony`: [tony/libtmux-lua](https://github.com/tony/libtmux-lua).

The organization repository is public; the personal repository is private.
They are independent, with `master` as the default branch. The personal
repository is not a GitHub fork. Push only to `origin`.
