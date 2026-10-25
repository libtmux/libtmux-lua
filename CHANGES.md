# Changelog

## Unreleased

## 0.1.0alpha4-1

- Wait: add `Pane:wait_for_text`, which polls the visible screen on every
  supported tmux release and ends with `pane_died`, carrying the text seen so
  far, when the pane or server goes first. (#53)
- Support: `capabilities.json` marks the raw `break-pane` command as refused
  on exactly 3.7 and keeps `repair` for `Pane:break_out` only. (#53)
- Docs: state the released support promise in the compatibility page, name
  the tmux 3.7 requirement for pane-output watches and control observation in
  the README, and link the optional-feature table and `capabilities.json`
  there. (#49)
- Docs: document the limit on commands nested in another command, with
  the releases and failures it affects and the advice for `break-pane` on
  tmux 3.7, and link it from the README Support list. (#52)
- Docs: name 0.1.0alpha1-1 as the last release that supports tmux 3.2a.
  (#52)
- Docs: list the `luv` build prerequisites per platform in the README quick
  start. (#52)

## 0.1.0alpha3-1 (2026-10-24)

- Commands: refuse literal commands that are unsafe on the connected release
  before dispatch, with `unsupported` and effect `not_sent`: named buffer
  deletion and rename below 3.4, custom layouts without a checksum below 3.4,
  `refresh-client -l` below 3.6a (tmux 3.3a can stop when it asks an attached
  terminal for its clipboard, and 3.4 through 3.6 when that client leaves
  before answering), `split-window -p` on 3.4, `break-pane` on exactly 3.7,
  and names containing `:` or `.` on exactly 3.7. Typed operations keep
  working; a typed name containing `:` or `.` on exactly 3.7 now returns
  `unsupported` before dispatch.
  See the [proposal](https://github.com/libtmux/libtmux-lua/issues/32).
  (#36)
- Control: observation needs tmux 3.7 or newer and returns `unsupported`
  before any attachment, process or client on an older daemon. (#36)
- Support: add the `libtmux._internal.support.capabilities` registry, which
  holds the release each optional feature needs and which `Commands`,
  `Control`, named buffer deletion and mirrored layout refusals read, and
  publish it as `capabilities.json` for the documentation site. The registry
  also lists JSON layouts and the capture `trim_empty_cells` and `line_flags`
  options, and their release floors are read from it. (#36)
- Docs: list the packages in the README under linked headings, each with
  reference links and a tested example, and add READMEs for the core package
  and the unpublished MCP and workspace scaffolds.
- Docs: check that README Lua blocks match the example programs they quote,
  that README commands and source links name files that exist, and that each
  README opens with the centered logo of its own package.
- Docs: rebuild the READMEs by task. Each opens with a Quick start, gives
  every API its own linked heading and an example quoted from a program CI
  runs, and ends with what the package leaves out and its support and status.
  The install command names `libtmux` 0.1.0alpha3-1.
- Docs: check that each README opens with Quick start, closes with the
  leaves-out and support sections, keeps paragraphs and list items short and
  defines the link references it uses, and that a Lua block marked `excerpt`
  is a run of consecutive lines from its example program.
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
