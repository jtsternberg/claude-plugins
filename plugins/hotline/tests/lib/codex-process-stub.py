#!/usr/bin/env python3
"""Native lsof field framing and ps birth evidence; never inspect a real PID."""
import os
from pathlib import Path
import sys

mode, *args = sys.argv[1:]
pid = os.environ.get("HERDR_STUB_CODEX_PID", "5151")
if mode == "ps":
    if args != ["-p", pid, "-o", "lstart="]:
        sys.exit(1)
    state = Path(os.environ["HERDR_STATE"]) / "birth_reads"
    reads = int(state.read_text()) if state.exists() else 0
    state.write_text(str(reads + 1))
    print("Wed Nov  4 12:00:01 2026" if os.environ.get("PS_STUB_CHANGE") == "1" and reads % 2 else "Wed Nov  4 12:00:00 2026")
    sys.exit(0)

# Resume-launch discovery: fixture agents do not own an open rollout descriptor.
if len(args) == 3 and args[:2] == ["-Fpc", "--"]:
    sys.exit(1)

if args not in (["-nP", "-a", "-p", pid, "-Fn"], ["-nP", "-a", "-p", pid, "-F0pcfDint"]):
    sys.exit(1)
if os.environ.get("LSOF_STUB_FAIL") == "1":
    sys.exit(1)
home_file = Path(os.environ["HERDR_STATE"]) / "process_home"
home = home_file.read_text() if home_file.exists() else os.environ.get("CODEX_HOME", os.environ["HOME"] + "/.codex")
rollout = os.environ.get("LSOF_STUB_ROLLOUT", home + "/sessions/2026/11/03/rollout-2026-11-03T12-56-13-01a1a28d-f07a-76a3-bbc7-21b555a6a8dc.jsonl")
extra = os.environ.get("LSOF_STUB_EXTRA", "")
if args[-1] == "-Fn":
    print("p" + pid + "\nn" + rollout)
    if extra:
        print("n" + extra)
    sys.exit(0)

st = Path(rollout).stat() if Path(rollout).exists() else None
dev = os.environ.get("LSOF_STUB_DEVICE", hex(st.st_dev) if st else "0x0")
ino = os.environ.get("LSOF_STUB_INODE", str(st.st_ino) if st else "0")
out = ("p" + os.environ.get("LSOF_STUB_PID", pid) + "\0ccodex\0\n"
       + "f7\0tREG\0D" + dev + "\0i" + ino + "\0n" + rollout + "\0\n")
native_record = os.environ.get("LSOF_STUB_NATIVE_NPOLICY", "")
if native_record:
    out += {
        "1": "f37\0tNPOLICY\0n\0\n",
        "missing-name": "f37\0tNPOLICY\0\n",
        "regular": "f37\0tREG\0n\0\n",
        "unknown": "f37\0tUNKNOWN\0n\0\n",
        "duplicate": "f37\0tNPOLICY\0n\0n\0\n",
        "contradictory": "f37\0tNPOLICY\0n\0i123\0\n",
        "nonnumeric": "fcwd\0tNPOLICY\0n\0\n",
        "truncated": "f37\0tNPOLICY\0n",
    }[native_record]
if extra:
    out += "f" + os.environ.get("LSOF_STUB_EXTRA_FD", "8") + "\0t" + os.environ.get("LSOF_STUB_EXTRA_TYPE", "REG") + "\0D" + dev + "\0i" + ino + "\0n" + extra
    if not extra.endswith("rollout-incomplete"):
        out += "\0\n"
sys.stdout.buffer.write(out.encode())
