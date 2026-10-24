"""Write capabilities.json from the Lua capability registry, or verify it."""

import argparse
from pathlib import Path
import subprocess
import sys

if __package__:
    from .check import lua_environment, tool
else:
    from check import lua_environment, tool

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "capabilities.json"


def emit(lua):
    result = subprocess.run(
        [lua, "scripts/emit_capabilities.lua"], cwd=ROOT, env=lua_environment(lua),
        capture_output=True, text=True, check=True)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if capabilities.json differs")
    parser.add_argument("--lua", default="lua", help="interpreter executable")
    args = parser.parse_args()
    expected = emit(tool(args.lua))
    if args.check:
        if not MANIFEST.exists() or MANIFEST.read_text() != expected:
            raise SystemExit(
                "capabilities.json differs from the registry; "
                "run python scripts/emit_capabilities.py")
    else:
        MANIFEST.write_text(expected)
    print("Capabilities " + ("check" if args.check else "generation") + " PASS")


if __name__ == "__main__":
    sys.exit(main())
