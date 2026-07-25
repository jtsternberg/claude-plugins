#!/usr/bin/env python3
"""Extract session data from Claude Code transcripts for daily note generation.

Scans ~/.claude/projects/ for .jsonl session files and extracts structured
data: user messages, follow-ups, dates, sizes, and subagent counts.
Outputs JSON grouped by date for Claude to synthesize into daily notes.

Usage:
    python3 extract_sessions.py [--since YYYY-MM-DD] [--until YYYY-MM-DD]
"""
import json
import os
import re
import signal
import subprocess
import argparse
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

# Exit cleanly when piped into `head`, `less`, etc. Without this, Python raises
# BrokenPipeError and prints a traceback to stderr/stdout.
if hasattr(signal, "SIGPIPE"):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def week_monday(date_str: str) -> str:
    """Return the Monday (YYYY-MM-DD) of the ISO week containing date_str."""
    d = datetime.strptime(date_str, "%Y-%m-%d").date()
    return (d - timedelta(days=d.weekday())).strftime("%Y-%m-%d")


def previous_week_range() -> tuple[str, str]:
    """Return (monday, sunday) of the week prior to the current one."""
    today = datetime.now().date()
    this_monday = today - timedelta(days=today.weekday())
    last_monday = this_monday - timedelta(days=7)
    last_sunday = this_monday - timedelta(days=1)
    return last_monday.strftime("%Y-%m-%d"), last_sunday.strftime("%Y-%m-%d")


EXPORT_BIN = (
    Path(__file__).resolve().parents[2]
    / "sessions-catch-up"
    / "scripts"
    / "export-session.mjs"
)


class ExportUnavailable(RuntimeError):
    """export-session.mjs could not be run — see the message for why."""


def genuine_user_messages(jsonl_path: Path) -> list[str]:
    """The things JT actually typed, per lib/transcript.mjs.

    Delegated rather than parsed here on purpose. This script used to read the
    JSONL itself with a generic strip-all-tags regex and no record filtering, so
    it counted as "user messages": harness-injected context (isMeta), SUBAGENT
    prompts (isSidechain), and Claude's own compaction summaries — none of which
    JT wrote. `--format text` applies the same contract the rest of session-tools
    uses and emits one flattened line per turn, `❯ ` for user turns.
    """
    if not EXPORT_BIN.is_file():
        raise ExportUnavailable(f"export-session.mjs not found at {EXPORT_BIN}")
    try:
        proc = subprocess.run(
            ["node", str(EXPORT_BIN), str(jsonl_path), "--format", "text", "--no-beads"],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except FileNotFoundError as exc:
        raise ExportUnavailable("node is required to read transcripts") from exc
    except subprocess.TimeoutExpired:
        return []
    if proc.returncode != 0:
        return []

    out: list[str] = []
    for line in proc.stdout.splitlines():
        if not line.startswith("❯ "):
            continue
        text = line[2:].strip()
        if len(text) > 5:
            out.append(text[:500])
    return out


# A commit shows up in tool output as git's own confirmation line — branch, short
# sha, subject: "[main 1a2b3c4] fix: thing", "[detached HEAD 1a2b3c4] …",
# "[main (root-commit) 1a2b3c4] …". Scanning for that is not the transcript
# contract above, just a targeted look at tool results, so it stays local.
#
# Note there is no literal "commit" in that output. The previous version required
# one (`"commit" in t.lower()`) on top of keying off a record type that does not
# exist, so it was doubly dead. The shape of the line is the signal.
COMMIT_LINE = re.compile(r"^\[.{0,60}?\b[0-9a-f]{7,40}\]\s+\S")
COMMIT_MARKERS = ("create mode", "file changed", "files changed", "insertion")


def session_commits(jsonl_path: Path) -> list[str]:
    """Commit confirmation lines out of tool output.

    Previously keyed off `type == "tool_result"`, which Claude Code does not emit
    as a record type — tool output is a `type:"user"` record whose content holds
    tool_result BLOCKS. So this never matched: 0 of 150 sessions in a real week
    produced a single commit.
    """
    commits: list[str] = []
    try:
        with open(jsonl_path, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or '"tool_result"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                content = entry.get("message", {}).get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict) or block.get("type") != "tool_result":
                        continue
                    body = block.get("content", "")
                    if isinstance(body, list):
                        body = " ".join(
                            b.get("text", "")
                            for b in body
                            if isinstance(b, dict)
                        )
                    if not isinstance(body, str):
                        continue
                    if not any(m in body for m in COMMIT_MARKERS):
                        continue
                    for cl in body.split("\n"):
                        cl = cl.strip()
                        if COMMIT_LINE.match(cl):
                            commits.append(cl[:200])
    except (OSError, IOError):
        pass
    return commits


def extract_session_data(jsonl_path: Path) -> dict:
    """Extract user messages and metadata from a session transcript."""
    return {
        "user_messages": genuine_user_messages(jsonl_path),
        "commits": session_commits(jsonl_path)[:10],
    }


def scan_sessions(
    projects_dir: Path,
    since: str | None = None,
    until: str | None = None,
    weekly: bool = False,
) -> dict:
    """Scan all projects for sessions and return data grouped by date or week."""
    results: list[dict] = []

    for jsonl in projects_dir.rglob("*.jsonl"):
        if jsonl.name == "history.jsonl":
            continue
        if "subagents" in str(jsonl):
            continue
        rel = jsonl.relative_to(projects_dir)
        if len(rel.parts) != 2:
            continue

        stat = jsonl.stat()
        mtime = datetime.fromtimestamp(stat.st_mtime)
        date_str = mtime.strftime("%Y-%m-%d")

        # Apply date filters
        if since and date_str < since:
            continue
        if until and date_str > until:
            continue

        # Count subagents
        session_dir = jsonl.parent / jsonl.stem
        subagent_count = 0
        if session_dir.is_dir():
            subagents_dir = session_dir / "subagents"
            if subagents_dir.is_dir():
                subagent_count = sum(
                    1 for _ in subagents_dir.rglob("*.jsonl")
                )

        data = extract_session_data(jsonl)

        if not data["user_messages"]:
            continue

        results.append(
            {
                "date": date_str,
                "time": mtime.strftime("%H:%M"),
                "size_bytes": stat.st_size,
                "subagent_count": subagent_count,
                "first_message": data["user_messages"][0],
                "follow_ups": data["user_messages"][1:8],
                "commits": data["commits"],
            }
        )

    # Group by date
    by_date: dict[str, list[dict]] = defaultdict(list)
    for r in results:
        by_date[r["date"]].append(r)

    # Sort sessions within each date by time
    for date_key in by_date:
        by_date[date_key].sort(key=lambda x: x["time"])

    if weekly:
        by_week: dict[str, list[dict]] = defaultdict(list)
        for date_key, sessions in by_date.items():
            monday = week_monday(date_key)
            by_week[monday].extend(sessions)
        for monday in by_week:
            by_week[monday].sort(key=lambda x: (x["date"], x["time"]))
        return {
            "weeks": dict(sorted(by_week.items())),
            "total_sessions": len(results),
            "date_range": {
                "earliest": min(by_date.keys()) if by_date else None,
                "latest": max(by_date.keys()) if by_date else None,
            },
        }

    return {
        "dates": dict(sorted(by_date.items())),
        "total_sessions": len(results),
        "date_range": {
            "earliest": min(by_date.keys()) if by_date else None,
            "latest": max(by_date.keys()) if by_date else None,
        },
    }


DEFAULT_SINCE_DAYS = 7


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Extract session data for daily notes"
    )
    parser.add_argument(
        "--since",
        type=str,
        help=f"Only include sessions from this date onward (YYYY-MM-DD). Default: {DEFAULT_SINCE_DAYS} days ago.",
    )
    parser.add_argument(
        "--until",
        type=str,
        help="Only include sessions up to this date (YYYY-MM-DD)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Include all sessions regardless of age (overrides --since default)",
    )
    parser.add_argument(
        "--weekly",
        action="store_true",
        help="Group sessions by ISO week (Mon-Sun). Defaults the date range to the previous full week when --since/--until are omitted.",
    )
    args = parser.parse_args()

    if args.weekly and not args.since and not args.until and not args.all:
        args.since, args.until = previous_week_range()
    elif not args.since and not args.all:
        args.since = (datetime.now() - timedelta(days=DEFAULT_SINCE_DAYS)).strftime("%Y-%m-%d")

    projects_dir = Path(os.path.expanduser("~/.claude/projects"))
    if not projects_dir.exists():
        print(json.dumps({"error": "No ~/.claude/projects/ directory found."}))
        exit(1)

    data = scan_sessions(projects_dir, since=args.since, until=args.until, weekly=args.weekly)
    print(json.dumps(data, indent=2))
