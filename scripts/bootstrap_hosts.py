"""Install pinned Neovim hosts in the local cache, outside test loops."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
# Official v0.10.x checksum assets and v0.11+/v0.12+ release asset digests.
RELEASES = {
    "0.10.0": ("nvim-linux64", "be1f0988d0de71c375982b87b86cd28d2bab35ece8285abe3b0aac57604dfc5a"),
    "0.10.4": ("nvim-linux-x86_64", "95aaa8e89473f5421114f2787c13ae0ec6e11ebbd1a13a1bd6fcf63420f8073f"),
    "0.11.7": ("nvim-linux-x86_64", "38a7c6317f94503841096c00e8fde05ef04b9472fc9d7d62b6e033cecd6f7991"),
    "0.12.5": ("nvim-linux-x86_64", "bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875"),
}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def probe(executable, version):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("LUA_", "LUA_PATH", "LUA_CPATH", "LUA_INIT", "VIM", "NVIM"))}
    with tempfile.TemporaryDirectory(prefix="libtmux-lua-nvim-probe-") as directory:
        for name in ("CONFIG", "CACHE", "DATA", "STATE"):
            env[f"XDG_{name}_HOME"] = str(Path(directory) / name.lower())
        result = subprocess.run([str(executable), "--version"], env=env, capture_output=True,
                                text=True, check=True, timeout=0.8)
        if result.stdout.splitlines()[0] != f"NVIM v{version}":
            raise ValueError(f"Neovim executable does not match version {version}")
        # The official 0.10.0 artifact reports prerelease="dev" through vim.version().
        # Verify its pinned artifact and CLI version; retain the API label as evidence.
        code = (
            "local v=vim.version(); "
            "local version=string.format('%d.%d.%d',v.major,v.minor,v.patch); "
            f"assert(version=='{version}'); "
            "assert(type(vim.schedule)=='function' and type(vim.system)=='function'); "
            "assert(type(vim.uv.hrtime)=='function' and type(vim.uv.new_timer)=='function'); "
            "io.stdout:write(vim.json.encode({version=version,reported_prerelease=v.prerelease or false,lua=_VERSION,"
            "jit=jit and jit.version or false,libuv=vim.uv.version_string()}),'\\n')"
        )
        result = subprocess.run(
            [str(executable), "--headless", "-u", "NONE", "-i", "NONE", "-n",
             "-c", "lua " + code, "-c", "qa!"], env=env, capture_output=True,
            text=True, check=True, timeout=0.8,
        )
        # A Lua command error may still be followed by qa! with exit status zero.
        if result.stderr:
            raise ValueError(f"Neovim headless probe failed: {result.stderr.strip()}")
        report = json.loads(result.stdout)
        if report.get("version") != version:
            raise ValueError("Neovim headless probe returned a different version")
        return report


def bootstrap(version, check_only):
    flavor, checksum = RELEASES[version]
    asset = f"{flavor}.tar.gz"
    url = f"https://github.com/neovim/neovim/releases/download/v{version}/{asset}"
    source = CACHE / "source" / f"nvim-{version}"
    archive = source / asset
    prefix = CACHE / "toolchains" / f"nvim-{version}"
    executable = prefix / "bin/nvim"
    receipt = prefix / ".libtmux-host.json"
    if not archive.exists():
        if check_only:
            raise FileNotFoundError(f"Missing cached Neovim archive for {version}; run bootstrap")
        source.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="download-", dir=source) as directory:
            temporary = Path(directory) / asset
            with urllib.request.urlopen(url, timeout=30) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if digest(temporary) != checksum:
                raise ValueError(f"SHA256 mismatch for Neovim {version}")
            temporary.replace(archive)
    if digest(archive) != checksum:
        raise ValueError(f"Cached artifact SHA256 mismatch for Neovim {version}")
    expected = {"version": version, "platform": "Linux-x86_64",
                "artifact_url": url, "artifact_sha256": checksum}
    installed = False
    if not prefix.exists():
        if check_only:
            raise FileNotFoundError(f"Missing cached Neovim host for {version}; run bootstrap")
        prefix.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=f"nvim-{version}-", dir=prefix.parent) as directory:
            staging = Path(directory)
            with tarfile.open(archive) as packed:
                packed.extractall(staging, filter="data")
            payload = staging / flavor
            if not (payload / "bin/nvim").is_file():
                raise ValueError(f"Neovim {version} archive lacks its expected executable")
            payload.replace(prefix)
            installed = True
    try:
        executable_hash = digest(executable)
        if not installed:
            stored = json.loads(receipt.read_text())
            if any(stored.get(key) != value for key, value in expected.items()):
                raise ValueError(f"Neovim {version} cache receipt differs from the artifact pin")
            if stored.get("executable_sha256") != executable_hash:
                raise ValueError(f"Neovim {version} executable changed since installation")
        report = probe(executable, version)
        record = dict(expected, executable_sha256=executable_hash, host=report)
        if installed:
            receipt.write_text(json.dumps(record, indent=2) + "\n")
    except BaseException:
        if installed:
            shutil.rmtree(prefix)
        raise
    return dict(record, executable=str(executable), status="READY")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("versions", nargs="+", choices=RELEASES)
    parser.add_argument("--check", action="store_true", help="verify cached hosts without network or installs")
    args = parser.parse_args()
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise SystemExit("No pinned Neovim bootstrap artifact for this host; matrix cell remains untested")
    failures = 0
    started = time.monotonic()
    for version in args.versions:
        cell_started = time.monotonic()
        try:
            report = bootstrap(version, args.check)
        except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
            failures += 1
            report = {"version": version, "status": "UNTESTED", "error": str(error)}
        report["bootstrap_seconds"] = round(time.monotonic() - cell_started, 4)
        print(json.dumps(report), flush=True)
    print(json.dumps({"bootstrap_seconds": round(time.monotonic() - started, 4),
                      "unready_hosts": failures}), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
