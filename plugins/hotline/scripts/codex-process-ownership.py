#!/usr/bin/env python3
"""Verify descriptor identity, not just the name lsof associates with an open file."""
import datetime
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def birth(pid):
    result = subprocess.run(
        ["ps", "-p", pid, "-o", "lstart="], capture_output=True, check=True,
        timeout=5, env={**os.environ, "LC_ALL": "C"},
    )
    value = result.stdout.decode().strip()
    if result.stderr:
        raise ValueError("unavailable process identity")
    datetime.datetime.strptime(value, "%a %b %d %H:%M:%S %Y")
    return value


def fields(record, allowed):
    result = {}
    for token in record.split(b"\0"):
        key, value = token[:1], token[1:]
        if key not in allowed or not value or key in result:
            raise ValueError("incomplete or inconsistent lsof record")
        result[key] = value
    return result


def verify(pid, path, thread):
    if not pid.isdecimal() or int(pid) <= 0:
        raise ValueError("invalid process identity")
    pinned = Path(path)
    if str(pinned.resolve(strict=True)) != path:
        raise ValueError("aliased rollout path")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd)
        current = os.stat(path, follow_symlinks=False)
        identity = (opened.st_dev, opened.st_ino)
        if not stat.S_ISREG(opened.st_mode) or not stat.S_ISREG(current.st_mode) or identity != (current.st_dev, current.st_ino):
            raise ValueError("rollout replaced before verification")
        with os.fdopen(os.dup(fd), "r", encoding="utf-8") as handle:
            header = json.loads(handle.readline())
        payload = header.get("payload", {}) if isinstance(header, dict) else {}
        if not isinstance(header, dict) or not isinstance(payload, dict) or header.get("type") != "session_meta" or (payload.get("id") or payload.get("session_id")) != thread:
            raise ValueError("rollout thread differs")

        started = birth(pid)
        result = subprocess.run(
            ["lsof", "-nP", "-a", "-p", pid, "-F0pcfDint"],
            capture_output=True, check=True, timeout=5,
        )
        data = result.stdout
        if result.stderr or not data.endswith(b"\0\n"):
            raise ValueError("incomplete lsof evidence")
        records = data.split(b"\0\n")[:-1]
        process = fields(records[0], {b"p", b"c"})
        if process != {b"p": pid.encode(), b"c": b"codex"}:
            raise ValueError("lsof process differs")
        owned = False
        for record in records[1:]:
            entry = fields(record, {b"f", b"t", b"D", b"i", b"n"})
            if not {b"f", b"t", b"n"} <= entry.keys():
                raise ValueError("unresolved file record")
            name = os.fsdecode(entry[b"n"])
            if name != path and (entry[b"t"] == b"DIR" or not Path(name).name.startswith("rollout-")):
                continue
            # Every rollout-like record must be complete and refer to this same
            # regular file. Deleted, truncated and second names are ambiguity.
            if name != path or entry[b"t"] != b"REG" or not entry[b"f"].isdigit():
                raise ValueError("ambiguous rollout ownership")
            device = int(entry[b"D"], 16)
            inode = int(entry[b"i"], 10)
            if (device, inode) != identity:
                raise ValueError("descriptor differs from current rollout")
            owned = True
        current = os.stat(path, follow_symlinks=False)
        if not owned or birth(pid) != started or not stat.S_ISREG(current.st_mode) or (current.st_dev, current.st_ino) != identity or str(pinned.resolve(strict=True)) != path:
            raise ValueError("ownership changed during verification")
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        verify(*sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError):
        # Do not print filenames, process environments or captured command output.
        sys.exit(1)
