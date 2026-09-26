#!/usr/bin/env python3
"""Build and test installed rocks offline; dependency setup is an outer step."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile

if __package__:
    from .release import REPOSITORY, candidate, identity, prepare
    from .runtime_config import executable_path, identify
else:
    from release import REPOSITORY, candidate, identity, prepare
    from runtime_config import executable_path, identify


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = {"luv": "1.52.1-0", "lunajson": "1.2.3-1", "lyaml": "6.2.9-1"}
PACKAGES = {
    "libtmux": ("lua", []),
    "libtmux-mcp": ("packages/mcp/lua", ["luv", "lunajson"]),
    "libtmux-workspace": ("packages/workspace/lua", ["luv", "lunajson", "lyaml"]),
}


def run(command, *, cwd, env, source=None):
    result = subprocess.run(
        command, cwd=cwd, env=env, input=source, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed ({result.returncode}):\n{result.stdout}")
    return result.stdout


def installed(tree, rocks, *, cwd):
    output = rocks([f"--tree={tree}", "list", "--porcelain"], cwd=cwd)
    return {line.split("\t")[0] for line in output.splitlines() if line.strip()}


def inspect_spec(spec, source_root, expected_dependencies, *, lua, cwd, env, rock_version="scm-1"):
    source_version, _ = identity(candidate(ROOT))
    tag = "" if rock_version == "scm-1" else f"v{source_version}"
    output = run([lua, "-", str(spec), rock_version, tag, "git+" + REPOSITORY], cwd=cwd, env=env, source="""
assert(loadfile(arg[1]))()
assert(description.license == "MIT", "package license must be MIT")
assert(version == arg[2], "rockspec version mismatch")
assert((source.tag or "") == arg[3], "rockspec tag mismatch")
assert(source.url == arg[4], "rockspec repository mismatch")
assert(dependencies[1] == "lua >= 5.1, < 5.6", "Lua version constraint mismatch")
for _, dep in ipairs(dependencies) do print("dependency\\t" .. dep:match("^%S+")) end
for name, path in pairs(build.modules) do print("module\\t" .. name .. "\\t" .. path) end
""")
    lines = [line.split("\t") for line in output.splitlines()]
    actual_dependencies = {row[1] for row in lines if row[0] == "dependency"}
    if actual_dependencies != expected_dependencies:
        raise RuntimeError(f"{spec.name}: unexpected dependencies {actual_dependencies}")
    modules = {row[2] for row in lines if row[0] == "module"}
    discovered = {str(path.relative_to(ROOT)) for path in (ROOT / source_root).rglob("*.lua")}
    if modules != discovered:
        raise RuntimeError(f"{spec.name}: module inventory differs: {modules ^ discovered}")


def inspect_installed_license(name, prefix, version, rock_version="scm-1"):
    rock = prefix / "lib/luarocks" / f"rocks-{version}" / name / rock_version
    spec_name = f"{name}-{rock_version}.rockspec"
    if (rock / spec_name).read_bytes() != (ROOT / "rockspecs" / spec_name).read_bytes():
        raise RuntimeError(f"{name}: installed rockspec differs from its source metadata")
    if (rock / "doc/LICENSE").read_bytes() != (ROOT / "LICENSE").read_bytes():
        raise RuntimeError(f"{name}: installed license differs from the project MIT license")


def import_installed(name, prefix, version, *, lua, cwd, env):
    child_env = dict(env)
    child_env["LUA_PATH"] = f"{prefix}/share/lua/{version}/?.lua;{prefix}/share/lua/{version}/?/init.lua"
    child_env["LUA_CPATH"] = f"{prefix}/lib/lua/{version}/?.so"
    source = """
local tests = dofile("imports.lua")
tests.test_core_and_query_import_without_effects()
local core = require("libtmux")
"""
    source_version, _ = identity(candidate(ROOT))
    source += f'assert(core._VERSION == "{source_version}", "installed source version mismatch")\n'
    if name == "libtmux":
        source += """
for _, dep in ipairs({"luv", "lunajson", "lyaml", "libtmux_mcp", "libtmux_workspace"}) do
    assert(not pcall(require, dep), "core-only install includes " .. dep)
end
"""
    else:
        consumer = "mcp" if name == "libtmux-mcp" else "workspace"
        source += f"tests.test_{consumer}_import_without_effects()\n"
        for dependency in PACKAGES[name][1]:
            source += f'assert(type(require("{dependency}")) == "table")\n'
        other = "libtmux_workspace" if consumer == "mcp" else "libtmux_mcp"
        source += f'assert(not pcall(require, "{other}"), "consumer dependency leaked")\n'
        source += 'assert(not require("luv").loop_alive(), "import started a loop")\n'
    run([lua, "-"], cwd=cwd, env=child_env, source=source)
    if name == "libtmux":
        output = run([lua, "-"], cwd=cwd, env=child_env, source="""
local function forbidden() error("pure example attempted external I/O") end
io.open, io.popen, os.execute = forbidden, forbidden, forbidden
dofile("native_query.lua")
""")
        if output != "%1\tnvim\n%3\tvim\n":
            raise RuntimeError("installed native-query example returned unexpected output")


def live_example(prefix, version, *, lua, cwd, env):
    sys.path.insert(0, str(ROOT))
    from tests.support.tmux_fixture import TmuxFixture

    with TmuxFixture() as fixture:
        child_env = dict(env, TMUX_BIN=shutil.which(fixture.binary),
                         TMUX_SOCKET=str(fixture.socket))
        child_env["LUA_PATH"] = f"{prefix}/share/lua/{version}/?.lua;{prefix}/share/lua/{version}/?/init.lua"
        child_env["LUA_CPATH"] = f"{prefix}/lib/lua/{version}/?.so"
        output = run([lua, "snapshot.lua"], cwd=cwd, env=child_env)
        if output != "%0\t@0\n":
            raise RuntimeError("installed snapshot example returned unexpected output")
        if list(fixture.path.glob("libtmux-lua-pin-*")):
            raise RuntimeError("installed snapshot example leaked its socket alias")
        quickstart = run([lua, "quickstart.lua"], cwd=cwd, env=child_env)
        if not re.fullmatch(r"\$\d+\t@\d+\t%\d+\n", quickstart):
            raise RuntimeError(f"installed quickstart returned unexpected output: {quickstart!r}")
        if fixture.run("has-session", "-t", "quickstart", check=False).returncode == 0:
            raise RuntimeError("installed quickstart left its session running")
        fixture.run("has-session", "-t", "$0")
    print("PASS installed public snapshot/quickstart examples and borrowed-server cleanup", flush=True)


def source_rock(spec, work, env, *, rocks, public_tag):
    """Pack the committed spec, using an isolated source tree before the public tag exists."""
    packing = work / "source-rock"
    packing.mkdir()
    pack_env = dict(env)
    if not public_tag:
        repository = work / "source-repository"
        repository.mkdir()
        source_version, revision = identity(candidate(ROOT))
        source_tag = "v" + source_version
        tagged = subprocess.run(["git", "rev-parse", "--verify", f"refs/tags/{source_tag}"],
                                cwd=ROOT, capture_output=True).returncode == 0
        if tagged:
            archive = subprocess.check_output(["git", "archive", source_tag], cwd=ROOT)
            with tarfile.open(fileobj=io.BytesIO(archive)) as packed:
                packed.extractall(repository, filter="data")
        elif revision > 1:
            raise RuntimeError("fetch the original source tag before checking a packaging revision")
        else:
            files = subprocess.check_output(
                ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
            ).decode().split("\0")
            for filename in filter(None, files):
                path = ROOT / filename
                if path.is_file():
                    destination = repository / filename
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, destination, follow_symlinks=False)
        for arguments in (["init", "-q"], ["add", "."],
                          ["-c", "user.name=Release fixture", "-c", "user.email=release@example.invalid",
                           "-c", "commit.gpgsign=false", "commit", "-qm", "Candidate source"],
                          ["tag", "v" + identity(candidate(ROOT))[0]]):
            run(["git", *arguments], cwd=repository, env=pack_env)
        pack_env.update({
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_COUNT": "1", "GIT_ALLOW_PROTOCOL": "file",
            "GIT_CONFIG_KEY_0": f"url.{repository.as_uri()}.insteadOf",
            "GIT_CONFIG_VALUE_0": REPOSITORY,
        })
    rocks([f"--tree={packing / 'tree'}", "pack", str(spec)], cwd=packing, override_env=pack_env)
    artifact = packing / spec.name.replace(".rockspec", ".src.rock")
    with zipfile.ZipFile(artifact) as packed:
        if packed.read(spec.name) != spec.read_bytes():
            raise RuntimeError("source rock embeds a different release rockspec")
        expected = {"libtmux-lua/" + str(path.relative_to(ROOT)): path.read_bytes()
                    for path in (ROOT / "lua").rglob("*.lua")}
        actual = {name for name in packed.namelist() if name.startswith("libtmux-lua/lua/") and name.endswith(".lua")}
        if actual != set(expected):
            raise RuntimeError("source rock Lua module inventory differs from the tested checkout")
        expected["libtmux-lua/LICENSE"] = (ROOT / "LICENSE").read_bytes()
        for name, content in expected.items():
            if packed.read(name) != content:
                raise RuntimeError(f"source rock differs from the tested checkout: {name}")
    return artifact


def check_release(work, env, *, rocks, lua, runtime, cache, output, public_tag):
    rock_version = candidate(ROOT)
    prepare(ROOT, rock_version, check=True)
    spec = ROOT / "rockspecs" / f"libtmux-{rock_version}.rockspec"
    inspect_spec(spec, "lua", {"lua"}, lua=lua, cwd=work, env=env, rock_version=rock_version)
    rocks([f"--tree={work / 'lint-tree'}", "lint", str(spec)], cwd=work)
    artifact = source_rock(spec, work, env, rocks=rocks, public_tag=public_tag)
    prefix = work / "installed-release"
    rocks([f"--tree={prefix}", "install", "--deps-mode=one", str(artifact)], cwd=work)
    if installed(prefix, rocks, cwd=work) != {"libtmux"}:
        raise RuntimeError("core release includes unexpected dependencies")
    inspect_installed_license("libtmux", prefix, runtime.version, rock_version)
    import_installed("libtmux", prefix, runtime.version, lua=lua, cwd=work, env=env)
    # Add the explicit standalone adapter dependency only after proving the core boundary.
    rocks([f"--tree={cache}", "pack", "luv", DEPENDENCIES["luv"]], cwd=work)
    luv = next(work.glob(f"luv-{DEPENDENCIES['luv']}.*.rock"))
    rocks([f"--tree={prefix}", "install", "--deps-mode=one", str(luv)], cwd=work)
    live_example(prefix, runtime.version, lua=lua, cwd=work, env=env)
    if output:
        output.mkdir(parents=True, exist_ok=True)
        names = (spec.name, artifact.name)
        if any((output / name).exists() for name in (*names, "SHA256SUMS", "candidate.json")):
            raise RuntimeError("output already contains release artifacts; select an empty directory")
        for source in (spec, artifact):
            shutil.copyfile(source, output / source.name)
        hashes = {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in names}
        (output / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in hashes.items()))
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))
        (output / "candidate.json").write_text(json.dumps({
            "package": "libtmux", "version": rock_version, "head": head, "dirty": dirty,
            "source": "public-tag" if public_tag else "local-fixture",
            "artifacts": hashes,
        }, indent=2) + "\n")
    print(f"PASS libtmux {rock_version}: source rock, isolated install, MIT, version, imports, examples", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--core-only", action="store_true", help="check core without consumer prerequisites")
    scope.add_argument("--package", choices=PACKAGES, help="check one package and its core dependency")
    scope.add_argument("--release", action="store_true", help="check only the core release candidate")
    parser.add_argument("--output", type=Path, help="retain validated release artifacts in an empty directory")
    parser.add_argument("--public-tag", action="store_true", help="fetch the actual public source tag (network)")
    parser.add_argument("--cache", type=Path, help="installed prerequisite LuaRocks tree")
    parser.add_argument("--lua", default="lua", help="interpreter executable")
    parser.add_argument("--luarocks", default="luarocks", help="LuaRocks executable")
    parser.add_argument("--yaml-dir", type=Path, help="LibYAML prefix (defaults to .cache/libyaml if present)")
    args = parser.parse_args()
    started = time.monotonic()
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT", "LUAROCKS_CONFIG"))
        and key not in {"TMUX", "TMUX_PANE"}
    }
    runtime = identify(args.lua)
    lua = runtime.executable
    luarocks = executable_path(args.luarocks)
    lua = str(Path(lua).resolve())
    lua_dir = Path(lua).parent.parent
    version = runtime.version
    rock_command = [luarocks, f"--lua-version={version}", f"--lua-dir={lua_dir}"]
    yaml_dir = args.yaml_dir or ROOT / ".cache" / "libyaml"
    rock_variables = [f"YAML_DIR={yaml_dir.resolve()}"] if yaml_dir.is_dir() else []

    def rocks(arguments, *, cwd, override_env=None):
        return run([*rock_command, *arguments, *rock_variables], cwd=cwd, env=override_env or env)

    cache = (args.cache or ROOT / ".cache" / "rocks" / runtime.cache_label).resolve()
    if args.release:
        selected = []
    elif args.core_only or args.package == "libtmux":
        selected = ["libtmux"]
    elif args.package:
        selected = ["libtmux", args.package]
    else:
        selected = list(PACKAGES)
    needed = {dependency for name in selected for dependency in PACKAGES[name][1]}
    with tempfile.TemporaryDirectory(prefix="libtmux-lua-packages-") as directory:
        work = Path(directory)
        # Empty servers make missing prerequisites fail locally instead of downloading.
        config = work / "config.lua"
        config_text = "rocks_servers = {}\nrocks_trees = {}\n"
        if rock_variables:
            # lyaml can link LibYAML statically; the external import verifies loadability.
            config_text += (
                'runtime_external_deps_patterns = { lib = { "lib?.so", '
                '"lib?.so.*", "lib?.dylib", "?.dll", "lib?.a" } }\n'
            )
        config.write_text(config_text, encoding="utf-8")
        env["LUAROCKS_CONFIG"] = str(config)
        env[f"LUAROCKS_CONFIG_{version.replace('.', '_')}"] = str(config)
        shutil.copyfile(ROOT / "tests/unit/imports.lua", work / "imports.lua")
        shutil.copyfile(ROOT / "examples/native_query.lua", work / "native_query.lua")
        shutil.copyfile(ROOT / "examples/snapshot.lua", work / "snapshot.lua")
        shutil.copyfile(ROOT / "examples/quickstart.lua", work / "quickstart.lua")
        artifacts = work / "artifacts"
        artifacts.mkdir()
        dependency_rocks = {}
        if needed:
            for dependency, pinned in DEPENDENCIES.items():
                if dependency not in needed:
                    continue
                spec = cache / "lib/luarocks" / f"rocks-{version}" / dependency / pinned / f"{dependency}-{pinned}.rockspec"
                if not spec.is_file():
                    raise RuntimeError(
                        f"missing cached {dependency} {pinned}; "
                        "run scripts/bootstrap.py live consumers first"
                    )
                rocks([f"--tree={cache}", "pack", dependency, pinned], cwd=artifacts)
                dependency_rocks[dependency] = next(artifacts.glob(f"{dependency}-{pinned}.*.rock"))
        built = {}
        live_example_checked = False
        for name in selected:
            source_root, dependencies = PACKAGES[name]
            spec = ROOT / "rockspecs" / f"{name}-scm-1.rockspec"
            expected = {"lua", *dependencies}
            if name != "libtmux":
                expected.add("libtmux")
            inspect_spec(spec, source_root, expected, lua=lua, cwd=work, env=env)
            build = work / f"build-{name}"
            build.mkdir()
            shutil.copytree(ROOT / source_root, build / source_root)
            shutil.copyfile(spec, build / spec.name)
            shutil.copyfile(ROOT / "LICENSE", build / "LICENSE")
            build_prefix = work / f"build-tree-{name}"
            prerequisites = [dependency_rocks[dep] for dep in dependencies]
            if name != "libtmux":
                prerequisites.insert(0, built["libtmux"])
            for artifact in prerequisites:
                rocks([
                    f"--tree={build_prefix}", "install", "--deps-mode=one", str(artifact),
                ], cwd=work)
            rocks([
                f"--tree={build_prefix}", "make", "--deps-mode=one", spec.name,
            ], cwd=build)
            rocks([f"--tree={build_prefix}", "pack", name, "scm-1"], cwd=build)
            artifact = next(build.glob(f"{name}-scm-1.*.rock"))
            built[name] = artifacts / artifact.name
            shutil.copyfile(artifact, built[name])
            prefix = work / f"installed-{name}"
            for artifact in [*prerequisites, built[name]]:
                rocks([
                    f"--tree={prefix}", "install", "--deps-mode=one", str(artifact),
                ], cwd=work)
            expected_installed = {name, *dependencies}
            if name != "libtmux":
                expected_installed.add("libtmux")
            actual = installed(prefix, rocks, cwd=work)
            if actual != expected_installed:
                raise RuntimeError(f"{name}: installed closure {actual} != {expected_installed}")
            for installed_name in sorted(expected_installed & PACKAGES.keys()):
                inspect_installed_license(installed_name, prefix, version)
            import_installed(name, prefix, version, lua=lua, cwd=work, env=env)
            if "luv" in dependencies and not live_example_checked:
                live_example(prefix, version, lua=lua, cwd=work, env=env)
                live_example_checked = True
            print(f"PASS {name}: built artifact, isolated install, MIT license, imports, dependency closure", flush=True)
        check_release(work, env, rocks=rocks, lua=lua, runtime=runtime, cache=cache,
                      output=args.output.resolve() if args.output else None, public_tag=args.public_tag)
    print(f"PASS package checks: Lua {version}, {time.monotonic() - started:.3f}s")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, StopIteration, zipfile.BadZipFile) as exc:
        raise SystemExit(f"FAIL package checks: {exc}") from exc
