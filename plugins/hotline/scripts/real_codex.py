"""Resolve the real `codex` executable for headless, non-session subcommands.

cmux puts a per-surface shim first on PATH whose wrapper prepends
`--dangerously-bypass-hook-trust` to anything it doesn't recognize as a known
non-session subcommand, and `queue` isn't on its list, so `codex queue` rejects
the flag. Interactive launches keep going through the shim on purpose: cmux's
hooks are what make those sessions visible to it.
"""
import os
from pathlib import Path
import shutil


def real_codex():
    # Inspect executable wrappers only, never credentials/config or process environments.
    for directory in os.get_exec_path():
        candidate = shutil.which("codex", path=directory) if directory else None
        if not candidate or "cmux-cli-shims" in Path(candidate).parts:
            continue
        with open(candidate, "rb") as handle:
            if b"cmux-codex-wrapper" in handle.read(16384):
                continue
        return os.path.abspath(candidate)
    raise ValueError("real codex executable unavailable")
