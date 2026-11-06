#!/usr/bin/env python3
"""Recover only a proven caller surface; session maps are hints, never authority.

Reads selected cmux metadata and bounded ps ancestry (no argv or environments).
Prints the current pane/workspace/window/surface refs, or nothing on refusal.
"""
import json
import os
import re
import subprocess
import sys
import time

UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
DEADLINE = time.monotonic() + 5


def run(*args):
    budget = min(2, DEADLINE - time.monotonic())
    if budget <= 0:
        raise ValueError("deadline")
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=budget).stdout


def resolve():
    native_agent, native_session = "", ""
    if os.environ.get("CLAUDE_CODE_SESSION_ID"):
        native_agent, native_session = "claude", os.environ["CLAUDE_CODE_SESSION_ID"]
    elif os.environ.get("CODEX_THREAD_ID"):
        native_agent, native_session = "codex", os.environ["CODEX_THREAD_ID"]
    agent = os.environ.get("CMUX_CALLER_AGENT", native_agent)
    session = os.environ.get("CMUX_CALLER_SESSION_ID", native_session)
    if agent not in ("claude", "codex") or not UUID.fullmatch(session):
        return
    if native_session and (agent, session) != (native_agent, native_session):
        return
    data = json.loads(run("cmux", "sessions", "--agent", agent,
                          "--session", session, "--json"))
    # Refuse duplicates, including multiple stores/accounts for the same ID.
    records = data["sessions"]
    if (not isinstance(records, list) or len(records) != 1
            or data.get("total_matches", 1) != 1):
        return
    record = records[0]
    if record.get("agent") != agent or record.get("session_id") != session:
        return
    pid, sid = record.get("pid"), record.get("surface_id")
    if type(pid) is not int or pid <= 1 or not isinstance(sid, str) or not UUID.fullmatch(sid):
        return
    # PID must belong to THIS invocation, not just a live codex on some tty.
    current = os.getppid()
    seen = set()
    tty = None
    for _ in range(64):
        if current <= 1 or current in seen:
            return
        seen.add(current)
        fields = run("ps", "-p", str(current), "-o", "ppid=,tty=,comm=").strip().split(None, 2)
        if len(fields) != 3 or not fields[0].isdigit():
            return
        if current == pid:
            if os.path.basename(fields[2]) != agent or fields[1] in ("?", "??", "-"):
                return
            tty = fields[1].removeprefix("/dev/")
            break
        current = int(fields[0])
    if not tty:
        return
    tree = json.loads(run("cmux", "tree", "--all", "--json", "--id-format", "both"))
    matches = [(pane, ws, win, surface)
               for win in tree["windows"] for ws in win["workspaces"]
               for pane in ws["panes"] for surface in pane["surfaces"]
               if surface.get("id") == sid]
    if len(matches) != 1:
        return
    pane, ws, win, surface = matches[0]
    if surface.get("tty", "").removeprefix("/dev/") != tty:
        return
    refs = [pane.get("ref"), ws.get("ref"), win.get("ref"), surface.get("ref")]
    for value, kind in zip(refs, ("pane", "workspace", "window", "surface")):
        if not isinstance(value, str) or not re.fullmatch(kind + r":\d+", value):
            return
    print("\t".join(refs))


if __name__ == "__main__":
    try:
        resolve()
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        # No guessed handle, no metadata dump. The opener owns the diagnostic.
        sys.exit(1)
