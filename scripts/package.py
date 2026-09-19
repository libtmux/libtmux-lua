#!/usr/bin/env python3
"""Build and test installed rocks offline; dependency setup is an outer step."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

if __package__:
    from .runtime_config import executable_path, identify
else:
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


def inspect_spec(spec, source_root, expected_dependencies, *, lua, cwd, env):
    output = run([lua, "-", str(spec)], cwd=cwd, env=env, source="""
assert(loadfile(arg[1]))()
assert(description.license == "MIT", "package license must be MIT")
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


def inspect_installed_license(name, prefix, version):
    rock = prefix / "lib/luarocks" / f"rocks-{version}" / name / "scm-1"
    spec_name = f"{name}-scm-1.rockspec"
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
tests.test_core_development_metadata()
tests.test_core_and_query_import_without_effects()
local core = require("libtmux")
assert(core._VERSION == "scm")
"""
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
        fixture.run("has-session", "-t", "$0")
    print("PASS installed public snapshot example and borrowed-server cleanup", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--core-only", action="store_true", help="check core without consumer prerequisites")
    scope.add_argument("--package", choices=PACKAGES, help="check one package and its core dependency")
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

    def rocks(arguments, *, cwd):
        return run([*rock_command, *arguments, *rock_variables], cwd=cwd, env=env)

    cache = (args.cache or ROOT / ".cache" / "rocks" / runtime.cache_label).resolve()
    if args.core_only or args.package == "libtmux":
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
    print(f"PASS package checks: Lua {version}, {time.monotonic() - started:.3f}s")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, StopIteration) as exc:
        raise SystemExit(f"FAIL package checks: {exc}") from exc
