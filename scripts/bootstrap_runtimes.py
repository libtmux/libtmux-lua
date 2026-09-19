"""Build pinned Lua interpreters locally; never run inside a test gate."""

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
RELEASES = {
    "5.1.5": "2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333",
    "5.2.4": "b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b",
    "5.3.6": "fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60",
    "5.4.9": "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6",
    "5.5.1": "1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce",
}
LUAJIT_REVISION = "c6ffc141a8762b41703f9287d63d93622a13dd8f"


def build_luajit(source):
    directory = source / "luajit"
    prefix = ROOT / ".cache/toolchains/luajit-2.1"
    started = time.monotonic()
    if not directory.exists():
        subprocess.run(["git", "clone", "--filter=blob:none", "--no-checkout", "--",
                        "https://github.com/LuaJIT/LuaJIT.git", str(directory)], check=True)
        subprocess.run(["git", "-C", str(directory), "checkout", "--detach", LUAJIT_REVISION], check=True)
    revision = subprocess.check_output(["git", "-C", str(directory), "rev-parse", "HEAD"], text=True).strip()
    if revision != LUAJIT_REVISION:
        raise SystemExit("Cached LuaJIT checkout differs from the accepted revision")
    if subprocess.check_output(["git", "-C", str(directory), "status", "--porcelain", "--untracked-files=no"]):
        raise SystemExit("Cached LuaJIT tracked source has local edits")
    with (source / "luajit-build.log").open("w") as output:
        subprocess.run(["make", "-j4", f"PREFIX={prefix}"], cwd=directory,
                       stdout=output, stderr=subprocess.STDOUT, check=True)
        subprocess.run(["make", "install", f"PREFIX={prefix}"], cwd=directory,
                       stdout=output, stderr=subprocess.STDOUT, check=True)
    subprocess.run([str(prefix / "bin/luajit"), "-v"], check=True)
    print(json.dumps({"runtime": "LuaJIT 2.1", "source_revision": revision,
                      "bootstrap_seconds": round(time.monotonic() - started, 4)}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("versions", nargs="+", choices=(*RELEASES, "luajit"))
    args = parser.parse_args()
    if platform.system() not in ("Linux", "Darwin"):
        raise SystemExit("Bootstrap supports Linux and macOS only")
    source = ROOT / ".cache" / "source"
    source.mkdir(parents=True, exist_ok=True)
    for version in args.versions:
        if version == "luajit":
            build_luajit(source)
            continue
        start = time.monotonic()
        prefix = ROOT / ".cache" / "toolchains" / f"lua-{version}"
        executable = prefix / "bin" / "lua"
        if executable.exists():
            subprocess.run([str(executable), "-v"], check=True)
            continue
        archive = source / f"lua-{version}.tar.gz"
        if not archive.exists():
            with urllib.request.urlopen(f"https://www.lua.org/ftp/{archive.name}", timeout=30) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != RELEASES[version]:
            raise SystemExit(f"SHA256 mismatch: {archive.name}")
        with tarfile.open(archive) as packed:
            packed.extractall(source, filter="data")
        directory = source / f"lua-{version}"
        flags = "-DLUA_USE_POSIX -DLUA_USE_DLOPEN -fPIC"
        libraries = "-Wl,-E -ldl" if platform.system() == "Linux" else ""
        logfile = source / f"lua-{version}-build.log"
        with logfile.open("w") as output:
            subprocess.run(["make", "-C", "src", "-j4", "all", f"MYCFLAGS={flags}",
                            f"MYLIBS={libraries}"], cwd=directory, stdout=output,
                           stderr=subprocess.STDOUT, check=True)
            subprocess.run(["make", "install", f"INSTALL_TOP={prefix}"], cwd=directory,
                           stdout=output, stderr=subprocess.STDOUT, check=True)
        subprocess.run([str(executable), "-v"], check=True)
        print(json.dumps({"runtime": version, "source_sha256": RELEASES[version],
                          "bootstrap_seconds": round(time.monotonic() - start, 4)}), flush=True)


if __name__ == "__main__":
    main()
