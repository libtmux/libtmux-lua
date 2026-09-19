"""Install pinned native prerequisites and editor tooling outside test loops."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
YAML_REVISION = "2c891fc7a770e8ba2fec34fc6b545c672beb37e6"
LUALS = {
    ("Linux", "x86_64"): ("linux-x64", "e9235d2d72ef55bc41cf8c99cda2ed64777682024b4bb81f5dea425060c5cbb8"),
    ("Darwin", "arm64"): ("darwin-arm64", "0bc077f4447f076b4c92c14e9fd303f5b569eda2ec74b4dca2b55f75fae2e90c"),
}


def yaml():
    source = CACHE / "source/libyaml"
    prefix = CACHE / "libyaml"
    if not source.exists():
        subprocess.run(["git", "clone", "--depth=1", "--branch=0.2.5",
                        "https://github.com/yaml/libyaml.git", str(source)], check=True)
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if revision != YAML_REVISION:
        raise SystemExit("Cached LibYAML checkout does not match the pinned revision")
    subprocess.run(["cmake", "-S", str(source), "-B", str(source / "build"),
                    f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DBUILD_SHARED_LIBS=OFF",
                    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DYAML_BUILD_TESTING=OFF"], check=True)
    subprocess.run(["cmake", "--build", str(source / "build"), "-j4"], check=True)
    subprocess.run(["cmake", "--install", str(source / "build")], check=True)


def luals():
    host = (platform.system(), platform.machine())
    if host not in LUALS:
        raise SystemExit(f"No pinned LuaLS bootstrap artifact for {host}")
    flavor, digest = LUALS[host]
    name = f"lua-language-server-3.19.1-{flavor}.tar.gz"
    archive = CACHE / "source" / name
    if not archive.exists():
        with urllib.request.urlopen(
            f"https://github.com/LuaLS/lua-language-server/releases/download/3.19.1/{name}", timeout=30
        ) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise SystemExit("LuaLS artifact SHA256 mismatch")
    prefix = CACHE / "tools/luals-3.19.1"
    prefix.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as packed:
        packed.extractall(prefix, filter="data")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("components", nargs="+", choices=("yaml", "luals"))
    args = parser.parse_args()
    (CACHE / "source").mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    for name in args.components:
        {"yaml": yaml, "luals": luals}[name]()
    print(json.dumps({"bootstrap_seconds": round(time.monotonic() - started, 4)}))


if __name__ == "__main__":
    main()
