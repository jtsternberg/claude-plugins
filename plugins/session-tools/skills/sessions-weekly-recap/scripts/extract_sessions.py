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


def strip_tags(text: str) -> str:
    """Remove XML/HTML tags from text."""
    text = re.sub(r"<[^>]+>[^<]*</[^>]+>", "", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+/?>", "", text)
    return text.strip()


def extract_session_data(jsonl_path: Path) -> dict:
    """Extract user messages and metadata from a session transcript."""
    user_messages: list[str] = []
    commit_messages: list[str] = []

    try:
        with open(jsonl_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue

                msg_type = entry.get("type", "")

                if msg_type == "user":
                    content = entry.get("message", {}).get("content", "")
                    if isinstance(content, list):
                        parts = []
                        for c in content:
                            if isinstance(c, dict) and c.get("type") == "text":
                                parts.append(strip_tags(c.get("text", "")))
                        content = " ".join(parts)
                    else:
                        content = strip_tags(content)

                    content = re.sub(r"\s+", " ", content).strip()
                    if len(content) > 5:
                        user_messages.append(content[:500])

                elif msg_type == "tool_result":
                    result_content = entry.get("content", "")
                    if isinstance(result_content, list):
                        for c in result_content:
                            if isinstance(c, dict):
                                t = c.get("text", "")
                                if "commit" in t.lower() and (
                                    "create mode" in t
                                    or "file changed" in t
                                    or "insertion" in t
                                ):
                                    for cl in t.split("\n"):
                                        if cl.strip().startswith("[") and "]" in cl:
                                            commit_messages.append(
                                                cl.strip()[:200]
                                            )
    except (OSError, IOError):
        pass

    return {
        "user_messages": user_messages,
        "commits": commit_messages[:10],
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
