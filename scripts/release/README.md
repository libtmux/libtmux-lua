# Release preparation

`main.lua` prepares an explicit LuaRocks version, guards publication and, in
the Publish workflow only, publishes the verified artifacts. `prepare`,
`changelogs` and `verify` never commit, tag, push or upload.

| Command | Does |
| --- | --- |
| `prepare VERSION` | Writes `release.json`, `libtmux._VERSION`, the versioned rockspec (from `luarocks new_version`, formatted by StyLua) and the changelog heading. |
| `prepare --check` | Reports drift between those files and the version `release.json` names, and changes nothing. |
| `changelogs` | Requires CHANGES.md to open with the rock's name and hold an `## Unreleased` section. |
| `verify --event FILE --commit SHA` | The publication guard: a canonical tag push, a clean checkout of the tested commit on `origin/master`, and, with `--artifacts DIR`, the retained artifacts' checksums. |
| `upload --artifacts DIR` | Runs `luarocks upload` for the candidate's rockspec and source rock, with the temporary key in `LUAROCKS_API_KEY`. It stops before `luarocks` runs when the key is empty. |
| `github-release --tag TAG --artifacts DIR --bundle FILE` | Copies the attestation bundle beside the artifacts and runs `gh release create TAG --verify-tag` with the artifacts, `SHA256SUMS`, `candidate.json` and the bundle. A version whose source ends in `alphaN`, `betaN` or `rcN` is marked a pre-release. It refuses a missing asset. |

## Who runs it

- The `generated` gate runs `prepare --check` and `changelogs`.
- The `Validate release artifacts` step of [ci.yml](../../.github/workflows/ci.yml)
  and the upload job of [publish.yml](../../.github/workflows/publish.yml) run
  `verify`. That job then runs `upload` and `github-release`; both start
  `luarocks` or `gh` through `support.proc`, so the job installs the `live`
  rocks.
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
