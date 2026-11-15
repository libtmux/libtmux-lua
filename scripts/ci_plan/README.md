# CI plan

`ci_plan.lua` decides which jobs a CI run covers, so
[ci.yml](../../.github/workflows/ci.yml) names no tmux version. It reads
[data/ci-matrix.json](../../data/ci-matrix.json) and the tmux catalog
[data/tmux-options.json](../../data/tmux-options.json), then prints the job
matrix for the event that started the run.

## Who runs it

- The `plan` job of `ci.yml` runs `plan` on every run and passes the matrix
  to the `validate` job.
- The `required` job runs `verify`, which fails unless `plan` and `validate`
  both succeeded.
- A maintainer runs `plan` to preview a run before dispatching it.

## Run it

Preview a push. Run from any directory inside the repository:

```console
$ luajit scripts/ci_plan/ci_plan.lua plan \
    --event push
```

Preview a dispatch of one custom tmux ref with a debugging session:

```console
$ luajit scripts/ci_plan/ci_plan.lua plan \
    --event workflow_dispatch \
    --scope custom \
    --tmux-ref master \
    --tmate on-failure
```

`plan` prints the plan as JSON. With `--github-output FILE` it appends the
`scope`, `os`, `matrix` and `expected_jobs` outputs to FILE, and with
`--summary FILE` it appends the job summary. A refused plan prints
`plan: <reason>` to stderr, exits 1 and writes neither file. A usage error
exits 2.

`verify` reads the `NEEDS` environment variable, the JSON of the `needs`
context, and exits 1 with one `required:` line per failing job.

## Scopes

- `edges`: the default for a push, a pull request and a dispatch. The unit
  jobs, both outer jobs and the integration suite on the oldest and newest
  released tmux.
- `full`: the default for a schedule, and a dispatch that asks. The unit
  jobs, the outer jobs (the current one on the release `ci-matrix.json`
  pins), the refusal jobs and every catalog entry, development builds
  included.
- `custom`: only the tmux refs a dispatch names with `--tmux-ref`, at most 12
  jobs.

## Matrix fields

Each job has `name`, `gate`, `lua`, `tmux`, `nvim`, `client`, `build`, `ref`
and `tmate`. `ref` is what the shared `build-tmux` action builds:

- A development build in `ci-matrix.json` builds the `revision` the catalog
  records for it.
- Any other version the catalog or the refusal table lists builds as its own
  name.
- A custom ref builds as given, with `build` set to `ref`.
- The unit jobs build no tmux, so their `ref` is empty.

## Layout

- `ci_plan.lua`: the entry point. It puts `scripts/` on the module path and
  the LuaJIT rock tree on the rock paths, then calls `cli.lua`.
- `cli.lua`: argument parsing and output, with the process boundary passed
  in.
- `planner.lua`: the rules. Each rule calls its siblings through the module
  table, so a test can replace one.
- `tests/test_ci_plan.lua`: behavior checks, and for each rule a deliberate
  break the matching check has to notice.
- `../support/`: JSON with key order (`json.lua`), file reads and appends
  (`files.lua`), the repository root and rock tree (`repo.lua`), and the
  suite runner (`run_tests.lua`).

Dependencies are the `lunajson` and `argparse` rocks in the LuaJIT rock tree
under `.cache/rocks`, and `luaunit` for the tests. None needs tmux, luv or
the network at run time.

## Test it

```console
$ luajit scripts/support/run_tests.lua \
    scripts/ci_plan/tests/test_ci_plan.lua \
    scripts/support/tests/test_support.lua
```
