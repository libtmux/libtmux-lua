"""Install pinned development dependencies outside the offline test loops."""

import argparse
import json
from pathlib import Path
import subprocess
import time

if __package__:
    from .runtime_config import clean_environment, identify
else:
    from runtime_config import clean_environment, identify

ROOT = Path(__file__).resolve().parent.parent
DEPENDENCIES = {
    "dev": (("luaunit", "3.5-1"), ("lunajson", "1.2.3-1")),
    "lint": (("argparse", "0.7.2-1"), ("luafilesystem", "1.9.0-1"), ("luacheck", "1.2.0-1")),
    "live": (("luv", "1.52.1-0"),),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("groups", nargs="+", choices=DEPENDENCIES)
    parser.add_argument("--lua", default="lua")
    parser.add_argument("--luarocks", default="luarocks")
    args = parser.parse_args()
    runtime = identify(args.lua)
    tree = ROOT / ".cache" / "rocks" / runtime.cache_label
    prefix = Path(runtime.executable).parent.parent
    env = clean_environment()
    base = [args.luarocks, f"--lua-version={runtime.version}", f"--lua-dir={prefix}", f"--tree={tree}"]
    started = time.monotonic()
    for group in args.groups:
        for name, pin in DEPENDENCIES[group]:
            existing = subprocess.run([*base, "show", name, pin], env=env, capture_output=True)
            if existing.returncode == 0:
                print(f"Installed: {name} {pin}", flush=True)
                continue
            subprocess.run([*base, "install", name, pin], cwd=ROOT, env=env, check=True)
    print(json.dumps({"bootstrap_seconds": round(time.monotonic() - started, 4)}))


if __name__ == "__main__":
    main()
