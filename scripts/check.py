"""Timed, offline development gates; dependency setup is a separate command."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

if __package__:
    from .runtime_config import clean_environment, executable_path, identify
else:
    from runtime_config import clean_environment, executable_path, identify

ROOT = Path(__file__).resolve().parent.parent


def run(command, *, env=None, timeout=290):
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, env=env, timeout=timeout)
    elapsed = time.monotonic() - started
    print(json.dumps({"command": command, "exit_code": result.returncode,
                      "wall_seconds": round(elapsed, 4)}), flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)


def tool(name):
    result = shutil.which(name)
    if result is None:
        raise SystemExit(f"Missing {name}; run the documented bootstrap first")
    return result


def lua_environment(lua):
    env = clean_environment()
    runtime = identify(lua)
    version = runtime.version
    tree = ROOT / ".cache" / "rocks" / runtime.cache_label
    share = tree / "share" / "lua" / version
    library = tree / "lib" / "lua" / version
    env["LUA_PATH"] = ";".join(str(p) for p in (
        ROOT / "lua/?.lua", ROOT / "lua/?/init.lua",
        ROOT / "packages/mcp/lua/?.lua", ROOT / "packages/mcp/lua/?/init.lua",
        ROOT / "packages/workspace/lua/?.lua", ROOT / "packages/workspace/lua/?/init.lua",
        ROOT / "?.lua", ROOT / "?/init.lua", share / "?.lua", share / "?/init.lua"
    ))
    env["LUA_CPATH"] = str(library / "?.so")
    env["PATH"] = os.pathsep.join((str(tree / "bin"), str(Path(runtime.executable).parent), env.get("PATH", "")))
    env["LIBTMUX_TEST_LUA"] = runtime.executable
    return env


def docs():
    files = [ROOT / "AGENTS.md", *ROOT.glob("README*.md"),
             *ROOT.glob(".github/*.md"), *ROOT.glob("docs/**/*.md")]
    for path in files:
        for target in re.findall(r"\]\(([^)]+)\)", path.read_text()):
            if target.startswith(("https:", "http:", "#", "mailto:")):
                continue
            destination = target.split("#", 1)[0]
            if destination and not (path.parent / destination).exists():
                raise SystemExit(f"Broken link in {path.relative_to(ROOT)}: {target}")
    if not (ROOT / "CLAUDE.md").is_symlink() or os.readlink(ROOT / "CLAUDE.md") != "AGENTS.md":
        raise SystemExit("CLAUDE.md must remain a relative symlink to AGENTS.md")
    run(["git", "diff", "--check"], timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("gate", choices=("unit", "mid", "format", "lint", "generated", "docs", "integration", "package", "types", "outer"))
    parser.add_argument("suites", nargs="*", help="unit suite names")
    parser.add_argument("--lua", default="lua", help="interpreter executable")
    parser.add_argument("--nvim", help="Neovim executable for embedded integration tests")
    args = parser.parse_args()
    if args.suites and args.gate != "unit":
        parser.error("suite names apply only to the unit gate")
    started = time.monotonic()
    lua = tool(args.lua)
    env = lua_environment(lua)
    if args.nvim:
        env["LIBTMUX_TEST_NVIM"] = executable_path(args.nvim)

    def execute(gate):
        if gate == "unit":
            suites = args.suites or sorted(path.stem for path in (ROOT / "tests/unit").glob("*.lua"))
            if not suites:
                raise SystemExit("No unit suites discovered")
            run([lua, "tests/run.lua", *suites], env=env, timeout=5)
        elif gate == "format":
            run([tool("stylua"), "--check", "--syntax", "Lua51", "lua", "packages", "tests", "examples", "rockspecs"], timeout=10)
        elif gate == "lint":
            lint_lua = ROOT / ".cache/toolchains/lua-5.4.9/bin/lua"
            if not lint_lua.exists():
                raise SystemExit("Luacheck needs the pinned Lua 5.4.9 tool interpreter; see CONTRIBUTING.md")
            lint_env = lua_environment(str(lint_lua))
            executable = shutil.which("luacheck", path=lint_env["PATH"])
            if not executable:
                raise SystemExit("Missing luacheck; run scripts/bootstrap.py first")
            run([executable, "lua", "packages", "tests", "examples"], env=lint_env, timeout=10)
        elif gate == "docs":
            docs()
        elif gate == "generated":
            run([sys.executable, "scripts/generate_fields.py", "--check"], env=env, timeout=5)
        elif gate == "integration":
            run([sys.executable, "tests/run_integration.py"], env=env)
        elif gate == "package":
            run([sys.executable, "scripts/package.py", "--lua", lua], env=env)
        elif gate == "types":
            executable = ROOT / ".cache/tools/luals-3.19.1/bin/lua-language-server"
            if not executable.exists():
                raise SystemExit("Missing pinned LuaLS 3.19.1; see CONTRIBUTING.md")
            run([str(executable), "--check=.", "--checklevel=Warning", "--logpath=.cache/luals"], env=env)
            run([sys.executable, "scripts/check_editor.py"], env=env, timeout=20)
        elif gate == "mid":
            for item in ("unit", "format", "lint", "generated", "docs"):
                execute(item)
        elif gate == "outer":
            for item in ("mid", "integration", "package", "types"):
                execute(item)

    execute(args.gate)
    elapsed = time.monotonic() - started
    budget = 5 if args.gate == "unit" else 30 if args.gate == "mid" else 300
    print(json.dumps({"gate": args.gate, "wall_seconds": round(elapsed, 4),
                      "budget_seconds": budget, "status": "PASS" if elapsed < budget else "FAIL"}))
    if elapsed >= budget:
        raise SystemExit("Gate exceeded its whole-command budget")


if __name__ == "__main__":
    main()
