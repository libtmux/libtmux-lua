"""Prepare and validate explicit LuaRocks release versions without publishing."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


REPOSITORY = "https://github.com/libtmux/libtmux-lua.git"
NUMBER = r"(?:0|[1-9][0-9]*)"
VERSION = re.compile(rf"({NUMBER}\.{NUMBER}\.{NUMBER}(?:(?:alpha|beta|rc)[1-9][0-9]*)?)-([1-9][0-9]*)")


def identity(version):
    match = VERSION.fullmatch(version) if isinstance(version, str) else None
    if not match:
        raise ValueError("version must be MAJOR.MINOR.PATCH[alphaN|betaN|rcN]-REVISION")
    return match.group(1), int(match.group(2))


def candidate(root):
    metadata = json.loads((root / "release.json").read_text())
    if set(metadata) != {"package", "version"} or metadata["package"] != "libtmux":
        raise ValueError("release.json must identify the libtmux core only")
    identity(metadata["version"])
    return metadata["version"]


def command(arguments, *, cwd):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT", "LUAROCKS_CONFIG"))}
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout


def prepared_spec(root, version):
    source, _ = identity(version)
    with tempfile.TemporaryDirectory(prefix="libtmux-lua-version-") as directory:
        command([
            "luarocks", "new_version", str(root / "rockspecs/libtmux-scm-1.rockspec"),
            version, "--tag", f"v{source}", "--dir", directory,
        ], cwd=directory)
        path = Path(directory) / f"libtmux-{version}.rockspec"
        config = ["--config-path", str(root / "stylua.toml")] if (root / "stylua.toml").is_file() else []
        command(["stylua", "--syntax", "Lua51", *config, str(path)], cwd=root)
        return path.read_text()


def release_notes(notes, version):
    heading = f"## {version}\n"
    pattern = rf"^## {re.escape(version)}(?: \(\d{{4}}-\d{{2}}-\d{{2}}\))?$"
    if re.search(pattern, notes, re.MULTILINE):
        return notes
    marker = "## Unreleased\n"
    if marker not in notes:
        raise ValueError("CHANGES.md needs an Unreleased section")
    before, after = notes.split(marker, 1)
    entry, separator, older = after.partition("\n## ")
    if not entry.strip():
        raise ValueError("add release notes under Unreleased before preparing a version")
    return before + marker + "\n" + heading + "\n" + entry.strip() + "\n" + (
        "\n## " + older if separator else ""
    )


def prepare(root, version, *, check=False):
    source, _ = identity(version)
    spec = Path("rockspecs") / f"libtmux-{version}.rockspec"
    expected = {
        Path("release.json"): json.dumps({"package": "libtmux", "version": version}, indent=2) + "\n",
        Path("lua/libtmux/init.lua"): f'return {{ _VERSION = "{source}" }}\n',
        spec: prepared_spec(root, version),
        Path("CHANGES.md"): release_notes((root / "CHANGES.md").read_text(), version),
    }
    changed = {path: content for path, content in expected.items()
               if not (root / path).exists() or (root / path).read_text() != content}
    if check and changed:
        raise ValueError("release metadata drift: " + ", ".join(str(p) for p in changed))
    if changed and not check:
        tagged = subprocess.run(
            ["git", "rev-parse", "--verify", f"refs/tags/v{source}"], cwd=root,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode == 0
        if tagged and spec in changed and (root / spec).exists():
            raise ValueError("tagged release rockspec would change; use a new rockspec revision")
        for path, content in changed.items():
            (root / path).write_text(content)
    return version


def release_tag(version):
    source, revision = identity(version)
    return f"v{source}" if revision == 1 else f"rocks/{version}"


def verify_artifacts(root, directory, head):
    version = candidate(root)
    manifest = json.loads((directory / "candidate.json").read_text())
    if (manifest.get("package"), manifest.get("version"), manifest.get("head"),
            manifest.get("dirty"), manifest.get("source")) != (
            "libtmux", version, head, False, "public-tag"):
        raise ValueError("artifacts must come from this clean release commit and the public source tag")
    names = {f"libtmux-{version}.rockspec", f"libtmux-{version}.src.rock"}
    if set(manifest.get("artifacts", {})) != names:
        raise ValueError("release artifact inventory mismatch")
    for name, digest in manifest["artifacts"].items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"artifact checksum mismatch: {name}")
    spec_name = f"libtmux-{version}.rockspec"
    if (directory / spec_name).read_bytes() != (root / "rockspecs" / spec_name).read_bytes():
        raise ValueError("artifact rockspec differs from the reviewed release rockspec")
    sums = "".join(f"{digest}  {name}\n" for name, digest in manifest["artifacts"].items())
    if (directory / "SHA256SUMS").read_text() != sums:
        raise ValueError("SHA256SUMS differs from the validated artifacts")


def verify_release(root, event, commit, artifacts=None):
    version = candidate(root)
    source, revision = identity(version)
    if (event.get("repository", {}).get("full_name") != "libtmux/libtmux-lua" or
            event.get("ref") != f"refs/tags/{release_tag(version)}" or
            event.get("deleted") is not False):
        raise ValueError("publication requires a canonical version-tag push")
    head = command(["git", "rev-parse", "HEAD"], cwd=root).strip()
    tagged = command(["git", "rev-parse", f"refs/tags/{release_tag(version)}^{{commit}}"], cwd=root).strip()
    if head != commit or tagged != head:
        raise ValueError("release tag, checkout and tested commit differ")
    if command(["git", "status", "--porcelain"], cwd=root):
        raise ValueError("release checkout must be clean")
    result = subprocess.run(["git", "merge-base", "--is-ancestor", head, "refs/remotes/origin/master"], cwd=root)
    if result.returncode:
        raise ValueError("release commit must be on origin/master")
    if revision > 1:
        result = subprocess.run(["git", "merge-base", "--is-ancestor", f"refs/tags/v{source}", head], cwd=root)
        if result.returncode:
            raise ValueError("packaging revision must descend from its immutable source tag")
    if artifacts:
        verify_artifacts(root, artifacts, head)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preparation = commands.add_parser("prepare", help="update candidate metadata and release notes")
    preparation.add_argument("version", nargs="?", help="explicit LuaRocks version, including revision")
    preparation.add_argument("--check", action="store_true", help="report drift without changing files")
    verification = commands.add_parser("verify", help="check publication guards without uploading")
    verification.add_argument("--event", type=Path, required=True, help="GitHub tag-push event JSON")
    verification.add_argument("--commit", required=True, help="exact commit validated by the workflow")
    verification.add_argument("--artifacts", type=Path, help="directory containing validated artifacts")
    args = parser.parse_args()
    root = Path.cwd()
    if args.command == "verify":
        verify_release(root, json.loads(args.event.read_text()), args.commit, args.artifacts)
        print(f"PASS publication guards for {candidate(root)} at {args.commit}")
        return
    if args.version is None and not args.check:
        parser.error("prepare requires an explicit version")
    version = args.version or candidate(root)
    prepare(root, version, check=args.check)
    print(f"PASS {'checked' if args.check else 'prepared'} libtmux {version}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(f"FAIL {error}") from error
