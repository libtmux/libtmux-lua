"""Identify interpreter ABI and keep PUC and LuaJIT dependency trees distinct."""

from dataclasses import dataclass
import os
from pathlib import Path
import re
import shutil
import subprocess


def clean_environment():
    return {key: value for key, value in os.environ.items()
            if not key.startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}


@dataclass(frozen=True)
class LuaRuntime:
    executable: str
    version: str
    cache_label: str
    jit_version: str | None


def executable_path(executable):
    resolved = shutil.which(executable)
    if resolved is None:
        raise RuntimeError(f"Missing executable: {executable}")
    candidate = Path(resolved).absolute()
    target = candidate.resolve()
    if target.name == "mise" and candidate.name != "mise":
        resolved = subprocess.check_output(
            [str(target), "which", candidate.name], text=True,
            cwd=Path(__file__).resolve().parent.parent,
        ).strip()
    else:
        resolved = str(candidate)
    return resolved


def identify(executable):
    resolved = executable_path(executable)
    output = subprocess.check_output(
        [resolved, "-e", 'io.write((_VERSION:gsub("Lua ", "")), "\\n"); '
         'if jit then io.write(jit.version) end'],
        text=True, env=clean_environment(),
    ).splitlines()
    if len(output) not in (1, 2) or not re.fullmatch(r"5\.[1-5]", output[0]):
        raise RuntimeError("Interpreter reports an unrecognized Lua ABI")
    version = output[0]
    jit_version = output[1] if len(output) == 2 else None
    cache_label = version
    if jit_version is not None:
        match = re.fullmatch(r"LuaJIT (2\.1[.\w-]*)", jit_version)
        if not match or version != "5.1":
            raise RuntimeError("Interpreter reports an unrecognized LuaJIT version")
        cache_label = "luajit-" + match.group(1)
    return LuaRuntime(resolved, version, cache_label, jit_version)
