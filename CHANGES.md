# Changelog

## Unreleased

- Docs: list the packages in the README under linked headings, each with
  reference links and a tested example, and add READMEs for the core package
  and the unpublished MCP and workspace scaffolds.
- Docs: check that README Lua blocks match the example programs they quote,
  that README commands and source links name files that exist, and that each
  README opens with the centered logo of its own package.
- Examples: add `examples/nvim_snapshot.lua`, which the integration suite runs
  in headless Neovim.

## 0.1.0alpha2-1 (2026-10-18)

- Core: require tmux 3.3a, checked against the running tmux server rather
  than the `tmux` executable. Connecting to an older server, including 3.3
  without its patch letter, fails with `unsupported_version` before any
  command runs; upgrade tmux and restart the server after saving its
  sessions. A development build or release candidate is accepted when it
  ranks at or above 3.3a. See the
  [proposal](https://github.com/libtmux/libtmux-lua/issues/31). (#35)
- Core: a server older than tmux 3.2, which cannot answer the version
  probe, and a version report that names no release now fail with
  `unsupported_version` and a message that says to upgrade tmux and restart
  the server, or install the previous release; neither reads as a probe
  failure or as "too old". (#35)
- Core: reading the server's version no longer runs the user's tmux hooks,
  and a control attachment no longer runs `display-message`. (#35)
- Core: commands no longer start a version probe each. The version is read
  once when the endpoint connects, and a server replaced afterwards fails
  with `stale_generation` before any command runs. (#35)
- Releases: support tmux 3.7d, 3.8 and the pinned next-3.9 development
  build in option, buffer, topology and layout operations, including 3.8's
  JSON layouts and the metadata escapes it adds. (#35)
- Types: declare `libtmux.Session`, `Window`, `WindowLink`, `Pane`, `Client`
  and `Buffer` handle classes. Each lists only the methods tmux accepts for
  that kind; `Server:handle` returns the class that matches the record.
- Types: give each option, hook and environment operation its own options
  class, listing only the fields that operation accepts. `run_hook` takes
  `process` alone; `hidden` belongs to `set_environment`.
- Docs: add complete common API examples with private tmux setup and cleanup.
- Docs: show the `Server:handle` description on `handle`, not on `command`.
- Docs: describe `libtmux.Server` in the API reference, with its methods grouped
  by task.

## 0.1.0alpha1-1 (2026-09-20)

- Core: add explicit async requests, snapshots and queries for tmux objects.
- Core: add session, window, pane, buffer and client operations, with
  capability checks for tmux versions.
- Runtime: support explicit standalone luv and Neovim event-loop adapters.
- Packaging: prepare the first MIT-licensed core alpha. MCP and workspace
  packages remain development scaffolds and are not published.
