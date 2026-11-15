# Release preparation

`main.lua` prepares an explicit LuaRocks version and guards publication. It
never commits, tags, pushes or uploads.

| Command | Does |
| --- | --- |
| `prepare VERSION` | Writes `release.json`, `libtmux._VERSION`, the versioned rockspec (from `luarocks new_version`, formatted by StyLua) and the changelog heading. |
| `prepare --check` | Reports drift between those files and the version `release.json` names, and changes nothing. |
| `changelogs` | Requires CHANGES.md to open with the rock's name and hold an `## Unreleased` section. |
| `verify --event FILE --commit SHA` | The publication guard: a canonical tag push, a clean checkout of the tested commit on `origin/master`, and, with `--artifacts DIR`, the retained artifacts' checksums. |

## Who runs it

- The `generated` gate runs `prepare --check` and `changelogs`.
- The `Validate release artifacts` step of [ci.yml](../../.github/workflows/ci.yml)
  and the upload job of [publish.yml](../../.github/workflows/publish.yml) run
  `verify`.
- A maintainer runs `prepare`, as
  [CONTRIBUTING.md](../../.github/CONTRIBUTING.md#prepare-a-version) describes.

## Run it

Run from the repository root, with `luarocks` and `stylua` on `PATH`:

```console
$ luajit scripts/release/main.lua prepare --check
```

Run the tests:

```console
$ luajit scripts/support/run_tests.lua \
    scripts/release/tests/test_release.lua
```
