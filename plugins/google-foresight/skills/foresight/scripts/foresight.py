#!/usr/bin/env python3
"""Read (and carefully write) Google AI Edge Foresight meeting data.

Foresight keeps everything in one SQLite file. Its schema is an undocumented app
internal, so every command checks the columns it relies on first and exits 3 with
the mismatch spelled out rather than guessing.

Reads open the database with mode=ro. The only writes are `write-notes` and `restore`,
which update notes_table.content for one meeting behind a compare-and-swap hash, an
app-activity check, and a read-back verification. Before each write the note's prior
row goes to a small undo journal (JSONL, last 50 entries); a whole-database copy is
made only with --full-backup.

Exit codes: 0 ok, 1 runtime error, 2 usage, 3 schema mismatch, 4 meeting not found
or ambiguous, 5 write refused by a guard, 6 write did not verify.
"""

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.request import pathname2url

DEFAULT_DB = Path.home() / "Library/Application Support/com.google.AIEdgeForesight/database.sqlite"
DEFAULT_STATE_DIR = Path.home() / ".local/state/google-foresight"
JOURNAL_KEPT = 50
# PRAGMA user_version of the database these commands were checked against (app build 1.0.0.28).
TESTED_USER_VERSION = 5
QUIET_SECONDS_DEFAULT = 60

REQUIRED_COLUMNS = {
    "event_transcript_table": [
        "event_id", "timestamp", "event_name", "transcript",
        "post_event_summarization", "calendar_event_id", "attendees",
    ],
    "notes_table": [
        "id", "title", "content", "enhanced_content", "timestamp",
        "last_enhanced", "last_manual_edit",
    ],
}

EXIT_RUNTIME, EXIT_SCHEMA, EXIT_NOT_FOUND, EXIT_REFUSED, EXIT_UNVERIFIED = 1, 3, 4, 5, 6


OPEN_CONNECTIONS = []


class CliError(Exception):
    def __init__(self, message, code=EXIT_RUNTIME):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------- database access

def db_path(args):
    return Path(args.db or os.environ.get("FORESIGHT_DB") or DEFAULT_DB).expanduser()


def connect_ro(path):
    if not path.is_file():
        raise CliError(f"Foresight database not found at {path} (is the app installed and opened once?)")
    conn = sqlite3.connect(f"file:{pathname2url(str(path))}?mode=ro", uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    OPEN_CONNECTIONS.append(conn)
    return conn


def schema_problems(conn):
    problems = []
    for table, cols in REQUIRED_COLUMNS.items():
        have = {r["name"] for r in conn.execute(f"PRAGMA table_info({table})")}
        if not have:
            problems.append(f"missing table {table}")
            continue
        missing = [c for c in cols if c not in have]
        if missing:
            problems.append(f"{table} lacks column(s): {', '.join(missing)}")
    return problems


def check_schema(conn):
    problems = schema_problems(conn)
    if problems:
        raise CliError(
            "Foresight schema does not match what this tool understands — the app was "
            "probably updated. " + "; ".join(problems) + ". Run `doctor` for details; "
            "do not work around this by querying the database by hand.",
            EXIT_SCHEMA,
        )
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if version != TESTED_USER_VERSION:
        print(f"warning: database user_version {version} is untested (tested: {TESTED_USER_VERSION}); "
              "required columns are present, continuing", file=sys.stderr)


# ---------------------------------------------------------------- meeting model

def event_id_start(event_id):
    """Meeting start encoded in the id: event_<epoch ms>, or a calendar id ending _YYYYmmddTHHMMSSZ."""
    m = re.fullmatch(r"event_(\d{12,14})", event_id)
    if m:
        return int(m.group(1))
    m = re.search(r"_(\d{8}T\d{6}Z)$", event_id)
    if m:
        dt = datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        return int(dt.timestamp() * 1000)
    return None


def iso(ms):
    if ms is None:
        return None
    return datetime.fromtimestamp(ms / 1000).astimezone().isoformat(timespec="seconds")


def sha256(text):
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def parse_segments(event_id, raw):
    try:
        segments = json.loads(raw)
        for seg in segments:
            for turn in seg["turns"]:
                turn["speaker"], turn["text"]
    except (ValueError, TypeError, KeyError) as exc:
        raise CliError(
            f"transcript for {event_id} is not the expected JSON list of "
            f"{{segment_title, duration_seconds, turns:[{{speaker,text}}]}} ({exc!r}); "
            "the app's transcript format changed",
            EXIT_SCHEMA,
        )
    return segments


def load_meetings(conn, with_transcripts=False):
    """One record per event_id, merging transcript rows and the notes row."""
    meetings = {}

    def get(event_id):
        return meetings.setdefault(event_id, {
            "event_id": event_id, "title": None, "started_at_ms": None,
            "has_transcript": False, "transcript_rows": [], "duration_seconds": 0,
            "transcript_chars": 0, "summary": None, "attendees": [],
            "calendar_event_id": None, "note_id": None, "notes_chars": 0,
            "enhanced_chars": 0, "notes_updated_ms": None,
        })

    cols = "event_id, timestamp, event_name, post_event_summarization, calendar_event_id, attendees, transcript"
    for r in conn.execute(f"SELECT {cols} FROM event_transcript_table ORDER BY timestamp"):
        m = get(r["event_id"])
        m["has_transcript"] = True
        m["title"] = m["title"] or r["event_name"]
        if m["started_at_ms"] is None:
            m["started_at_ms"] = r["timestamp"]
        m["summary"] = r["post_event_summarization"] or m["summary"]
        m["calendar_event_id"] = r["calendar_event_id"] or m["calendar_event_id"]
        if r["attendees"]:
            m["attendees"] = [a.strip() for a in r["attendees"].split(",") if a.strip()]
        segments = parse_segments(r["event_id"], r["transcript"])
        m["duration_seconds"] += sum(int(s.get("duration_seconds") or 0) for s in segments)
        m["transcript_chars"] += sum(len(t["text"]) for s in segments for t in s["turns"])
        if with_transcripts:
            m["transcript_rows"].extend(segments)

    for r in conn.execute("SELECT id, title, length(content) c, length(enhanced_content) e, timestamp FROM notes_table"):
        event_id = r["id"][len("note_"):] if r["id"].startswith("note_") else r["id"]
        m = get(event_id)
        m["note_id"] = r["id"]
        # The notes title is the one the user can rename in the app; the transcript copy is a snapshot.
        m["title"] = r["title"] or m["title"]
        m["notes_chars"] = r["c"] or 0
        m["enhanced_chars"] = r["e"] or 0
        m["notes_updated_ms"] = r["timestamp"]

    for m in meetings.values():
        if m["started_at_ms"] is None:
            m["started_at_ms"] = event_id_start(m["event_id"]) or m["notes_updated_ms"]
        m["title"] = m["title"] or m["event_id"]
        m["started_at"] = iso(m["started_at_ms"])
    return sorted(meetings.values(), key=lambda m: m["started_at_ms"] or 0)


def local_date(ms):
    return datetime.fromtimestamp(ms / 1000).date()


def parse_day(text):
    try:
        return date.fromisoformat(text)
    except ValueError:
        raise CliError(f"not a YYYY-MM-DD date: {text}", 2)


def date_window(args):
    today = date.today()
    if getattr(args, "today", False):
        return today, today
    if getattr(args, "yesterday", False):
        y = today - timedelta(days=1)
        return y, y
    if getattr(args, "date", None):
        d = parse_day(args.date)
        return d, d
    since = parse_day(args.since) if getattr(args, "since", None) else None
    until = parse_day(args.until) if getattr(args, "until", None) else None
    return since, until


def filter_meetings(meetings, args):
    since, until = date_window(args)
    out = []
    for m in meetings:
        if m["started_at_ms"] is None and (since or until):
            continue
        d = local_date(m["started_at_ms"]) if m["started_at_ms"] is not None else None
        if since and d < since:
            continue
        if until and d > until:
            continue
        if getattr(args, "name", None) and args.name.lower() not in m["title"].lower():
            continue
        if getattr(args, "transcribed", False) and not m["has_transcript"]:
            continue
        out.append(m)
    return out


def resolve(conn, ref, with_transcripts=False):
    meetings = load_meetings(conn, with_transcripts)
    for m in meetings:
        if ref in (m["event_id"], m["note_id"]):
            return m
    hits = [m for m in meetings if ref.lower() in m["title"].lower()]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise CliError(f"no meeting matches {ref!r} (run `meetings` to list ids)", EXIT_NOT_FOUND)
    listing = "\n".join(f"  {m['event_id']}  {m['started_at']}  {m['title']}" for m in hits)
    raise CliError(f"{len(hits)} meetings match {ref!r}; pass an event_id:\n{listing}", EXIT_NOT_FOUND)


def read_note(conn, note_id):
    if not note_id:
        return None
    return conn.execute(
        "SELECT id, title, content, enhanced_content, timestamp, last_enhanced, last_manual_edit "
        "FROM notes_table WHERE id = ?", (note_id,)).fetchone()


# ---------------------------------------------------------------- output helpers

def emit(args, data, text):
    if args.json:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print(text)


def fmt_duration(seconds):
    if not seconds:
        return "-"
    h, rem = divmod(int(seconds), 3600)
    return f"{h}h{rem // 60:02d}m" if h else f"{rem // 60}m"


def public(m):
    keep = ("event_id", "title", "started_at", "duration_seconds", "has_transcript",
            "transcript_chars", "attendees", "calendar_event_id", "note_id",
            "notes_chars", "enhanced_chars")
    out = {k: m[k] for k in keep}
    out["has_summary"] = bool(m["summary"])
    out["notes_updated_at"] = iso(m["notes_updated_ms"])
    return out


def render_transcript(segments):
    """Consecutive turns by one speaker are joined, which roughly halves the line count."""
    lines = []
    for seg in segments:
        lines.append(f"## {seg.get('segment_title') or 'Transcript'} ({fmt_duration(seg.get('duration_seconds'))})")
        speaker, buf = None, []
        for turn in seg["turns"]:
            if turn["speaker"] != speaker and buf:
                lines.append(f"[{speaker}] {' '.join(buf)}")
                buf = []
            speaker = turn["speaker"]
            if turn["text"].strip():
                buf.append(turn["text"].strip())
        if buf:
            lines.append(f"[{speaker}] {' '.join(buf)}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def header(m):
    lines = [f"# {m['title']}", f"event_id: {m['event_id']}", f"started: {m['started_at']}",
             f"duration: {fmt_duration(m['duration_seconds'])}"]
    if m["attendees"]:
        lines.append(f"attendees: {', '.join(m['attendees'])}")
    return "\n".join(lines)


# ---------------------------------------------------------------- commands

def cmd_doctor(args):
    path = db_path(args)
    report = {"db": str(path), "exists": path.is_file(), "app_running": app_running(),
              "schema_ok": False, "problems": [], "user_version": None,
              "tested_user_version": TESTED_USER_VERSION}
    if report["exists"]:
        conn = connect_ro(path)
        report["user_version"] = conn.execute("PRAGMA user_version").fetchone()[0]
        report["problems"] = schema_problems(conn)
        report["schema_ok"] = not report["problems"]
        report["seconds_since_db_write"] = round(time.time() - path.stat().st_mtime)
        if report["schema_ok"]:
            ms = load_meetings(conn)
            report["meetings"] = len(ms)
            report["transcribed"] = sum(m["has_transcript"] for m in ms)
    text = "\n".join(f"{k}: {v}" for k, v in report.items())
    emit(args, report, text)
    return 0 if report["schema_ok"] else EXIT_SCHEMA


def cmd_meetings(args):
    conn = connect_ro(db_path(args))
    check_schema(conn)
    ms = filter_meetings(load_meetings(conn), args)
    if args.limit:
        ms = ms[-args.limit:]
    rows = []
    for m in ms:
        when = m["started_at"][:16].replace("T", " ") if m["started_at"] else "?"
        flags = ("T" if m["has_transcript"] else "-") + ("S" if m["summary"] else "-") + \
                ("N" if m["notes_chars"] else "-") + ("E" if m["enhanced_chars"] else "-")
        rows.append(f"{when}  {fmt_duration(m['duration_seconds']):>6}  {flags}  {m['event_id']}  {m['title']}")
    text = "\n".join(rows) if rows else "no meetings match"
    if rows:
        text += "\n\nflags: T=transcript S=app summary N=notes E=enhanced notes"
    emit(args, [public(m) for m in ms], text)
    return 0


def cmd_show(args):
    conn = connect_ro(db_path(args))
    check_schema(conn)
    m = resolve(conn, args.ref)
    note = read_note(conn, m["note_id"])
    data = public(m)
    data["summary"] = m["summary"]
    data["notes"] = note["content"] if note else None
    data["notes_sha256"] = sha256(note["content"]) if note else None
    data["enhanced_notes"] = note["enhanced_content"] if note else None
    parts = [header(m)]
    for label, body in (("App summary", m["summary"]), ("Notes", data["notes"]),
                        ("Enhanced notes", data["enhanced_notes"])):
        parts.append(f"\n## {label}\n{body if body else '(none)'}")
    emit(args, data, "\n".join(parts))
    return 0


def cmd_transcript(args):
    conn = connect_ro(db_path(args))
    check_schema(conn)
    m = resolve(conn, args.ref, with_transcripts=True)
    if not m["has_transcript"]:
        raise CliError(f"{m['event_id']} ({m['title']}) has no transcript", EXIT_NOT_FOUND)
    data = public(m)
    data["summary"] = m["summary"]
    data["segments"] = m["transcript_rows"]
    text = header(m) + "\n\n" + render_transcript(m["transcript_rows"])
    if args.with_summary and m["summary"]:
        text += f"\n## App summary\n{m['summary']}\n"
    emit(args, data, text)
    return 0


def cmd_notes(args):
    conn = connect_ro(db_path(args))
    check_schema(conn)
    m = resolve(conn, args.ref)
    note = read_note(conn, m["note_id"])
    if note is None:
        raise CliError(f"{m['event_id']} has no notes row in the app yet", EXIT_NOT_FOUND)
    field = "enhanced_content" if args.enhanced else "content"
    body = note[field] or ""
    data = {"event_id": m["event_id"], "note_id": note["id"], "title": note["title"],
            "field": field, "content": body, "content_sha256": sha256(note["content"]),
            "updated_at": iso(note["timestamp"]), "last_manual_edit": iso(note["last_manual_edit"]),
            "last_enhanced": iso(note["last_enhanced"])}
    emit(args, data, body)
    return 0


def snippet(text, i, n, width):
    start, end = max(0, i - width), min(len(text), i + n + width)
    s = text[start:end].replace("\n", " ")
    return ("…" if start else "") + s + ("…" if end < len(text) else "")


def cmd_search(args):
    conn = connect_ro(db_path(args))
    check_schema(conn)
    needle = args.query.lower()
    ms = filter_meetings(load_meetings(conn, with_transcripts=True), args)
    notes = {r["id"]: r for r in conn.execute("SELECT id, content, enhanced_content FROM notes_table")}
    hits = []

    def scan(m, field, text, speaker=None):
        low = (text or "").lower()
        i = low.find(needle)
        while i != -1 and len(hits) < args.limit:
            hits.append({"event_id": m["event_id"], "title": m["title"], "started_at": m["started_at"],
                         "field": field, "speaker": speaker,
                         "snippet": snippet(text, i, len(needle), args.context)})
            i = low.find(needle, i + len(needle))

    for m in ms:
        scan(m, "title", m["title"])
        for seg in m["transcript_rows"]:
            for turn in seg["turns"]:
                scan(m, "transcript", turn["text"], turn["speaker"])
        scan(m, "summary", m["summary"])
        note = notes.get(m["note_id"])
        if note:
            scan(m, "notes", note["content"])
            scan(m, "enhanced_notes", note["enhanced_content"])
    lines = []
    for h in hits:
        who = f" [{h['speaker']}]" if h["speaker"] else ""
        lines.append(f"{(h['started_at'] or '?')[:10]}  {h['event_id']}  {h['field']}{who}: {h['snippet']}")
    if len(hits) >= args.limit:
        lines.append(f"(stopped at --limit {args.limit})")
    emit(args, hits, "\n".join(lines) if lines else "no matches")
    return 0


# ---------------------------------------------------------------- guarded write

def app_running():
    name = os.environ.get("FORESIGHT_APP_PROCESS", "Foresight")
    try:
        return subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0
    except FileNotFoundError:
        return None


def state_dir(args):
    return Path(getattr(args, "state_dir", None) or os.environ.get("FORESIGHT_STATE_DIR")
                or DEFAULT_STATE_DIR).expanduser()


def journal_path(args):
    return state_dir(args) / "undo.jsonl"


def read_journal(args):
    path = journal_path(args)
    if not path.is_file():
        return []
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                entries.append(json.loads(line))
            except ValueError:
                print(f"warning: skipping unreadable undo journal line in {path}", file=sys.stderr)
    return entries


def append_journal(args, entry):
    """Rewrites the whole file through a temp + rename so a crash never leaves a torn journal."""
    path = journal_path(args)
    path.parent.mkdir(parents=True, exist_ok=True)
    entries = (read_journal(args) + [entry])[-JOURNAL_KEPT:]
    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_text("".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries), encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    return entry["undo_id"]


def full_backup(conn, args, event_id):
    backup_dir = state_dir(args) / "full-backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S%f")
    dest_path = backup_dir / f"database-{event_id}-{stamp}.sqlite"
    dest = sqlite3.connect(dest_path)
    with dest:
        conn.backup(dest)
    dest.close()
    if not dest_path.stat().st_size:
        raise CliError(f"full backup at {dest_path} is empty; refusing to write", EXIT_REFUSED)
    return dest_path


def check_app_quiet(args, path):
    running = app_running()
    if running and not args.allow_app_running:
        raise CliError("Foresight is running. A write while the app holds this note open (or while it is "
                       "recording) may be overwritten by the app or race with it — that behavior is untested. "
                       "Quit the app, or confirm with the user that this meeting is not open or recording "
                       "and pass --allow-app-running", EXIT_REFUSED)
    quiet = int(os.environ.get("FORESIGHT_QUIET_SECONDS", QUIET_SECONDS_DEFAULT))
    idle = time.time() - path.stat().st_mtime
    # Applies with the app quit too: its ForesightHelper process outlives the app window.
    if idle < quiet and not args.ignore_recent_activity:
        raise CliError(f"the database was written {idle:.0f}s ago, so the app is likely recording or "
                       f"saving; wait until it has been quiet for {quiet}s, or pass "
                       "--ignore-recent-activity after confirming with the user", EXIT_REFUSED)
    return running


def guarded_update(args, path, conn, m, note, values, action):
    """Shared by write-notes and restore: CAS on content, journal the prior row, update, read back."""
    current = note["content"] or ""
    if sha256(current) != args.expect_sha256:
        raise CliError(f"notes for {m['event_id']} changed since you read them (current sha256 "
                       f"{sha256(current)}); re-read with `notes {m['event_id']} --json`, merge, and retry",
                       EXIT_REFUSED)
    running = check_app_quiet(args, path)
    plan = {"action": action, "event_id": m["event_id"], "note_id": note["id"], "title": note["title"],
            "previous_sha256": sha256(current), "new_sha256": sha256(values["content"]),
            "previous_chars": len(current), "new_chars": len(values["content"]), "app_running": running}
    if args.dry_run:
        plan["dry_run"] = True
        emit(args, plan, "dry run, nothing written:\n" + "\n".join(f"  {k}: {v}" for k, v in plan.items()))
        return 0

    plan["undo_id"] = append_journal(args, {
        "undo_id": f"{int(time.time() * 1000)}-{note['id']}",
        "saved_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "action": action, "db": str(path), "event_id": m["event_id"],
        "row": {k: note[k] for k in note.keys()},
        "replaced_by_sha256": plan["new_sha256"],
    })
    if args.full_backup:
        plan["full_backup"] = str(full_backup(conn, args, m["event_id"]))
    conn.close()

    rw = sqlite3.connect(f"file:{pathname2url(str(path))}?mode=rw", uri=True, timeout=5, isolation_level=None)
    try:
        rw.execute("BEGIN IMMEDIATE")
        (again,) = rw.execute("SELECT content FROM notes_table WHERE id = ?", (note["id"],)).fetchone()
        if sha256(again) != plan["previous_sha256"]:
            rw.execute("ROLLBACK")
            raise CliError("notes changed between the check and the write; nothing written", EXIT_REFUSED)
        cols = ", ".join(f"{k} = ?" for k in values)
        cur = rw.execute(f"UPDATE notes_table SET {cols} WHERE id = ?", (*values.values(), note["id"]))
        if cur.rowcount != 1:
            rw.execute("ROLLBACK")
            raise CliError(f"update touched {cur.rowcount} rows; rolled back", EXIT_RUNTIME)
        rw.execute("COMMIT")
    finally:
        rw.close()

    check = read_note(connect_ro(path), note["id"])
    if check is None or any(check[k] != v for k, v in values.items()):
        raise CliError(f"write did not read back intact; `restore {m['event_id']} --undo-id {plan['undo_id']}` "
                       "puts the prior version back", EXIT_UNVERIFIED)
    plan["written"] = plan["verified"] = True
    emit(args, plan, f"{action}: {note['title']} ({m['event_id']}), verified on read-back\n"
                     f"undo_id: {plan['undo_id']}\nnew sha256: {plan['new_sha256']}")
    return 0


def open_for_write(args):
    path = db_path(args)
    conn = connect_ro(path)
    check_schema(conn)
    m = resolve(conn, args.ref)
    note = read_note(conn, m["note_id"])
    if note is None:
        raise CliError(f"{m['event_id']} has no notes row; open the meeting in Foresight once so the "
                       "app creates it, then retry (this tool never inserts rows)", EXIT_REFUSED)
    return path, conn, m, note


def cmd_write_notes(args):
    path, conn, m, note = open_for_write(args)
    current = note["content"] or ""
    incoming = Path(args.file).read_text(encoding="utf-8") if args.file != "-" else sys.stdin.read()
    new = (current.rstrip() + "\n\n" + incoming) if args.append and current.strip() else incoming
    if not new.strip():
        raise CliError("refusing to write empty notes", EXIT_REFUSED)
    now_ms = int(time.time() * 1000)
    # timestamp + last_manual_edit are what the app itself sets when the user edits a note.
    return guarded_update(args, path, conn, m, note,
                          {"content": new, "timestamp": now_ms, "last_manual_edit": now_ms},
                          "append" if args.append else "replace")


def journal_for(args, note_id):
    return [e for e in read_journal(args) if e.get("row", {}).get("id") == note_id]


def cmd_history(args):
    conn = connect_ro(db_path(args))
    check_schema(conn)
    m = resolve(conn, args.ref)
    entries = journal_for(args, m["note_id"])
    out = [{"undo_id": e["undo_id"], "saved_at": e["saved_at"], "action": e["action"],
            "prior_sha256": sha256(e["row"].get("content")), "prior_chars": len(e["row"].get("content") or ""),
            "replaced_by_sha256": e.get("replaced_by_sha256")} for e in entries]
    lines = [f"{e['undo_id']}  {e['saved_at']}  {e['action']:<8} prior {e['prior_chars']} chars" for e in out]
    emit(args, out, "\n".join(lines) if lines else f"no undo entries for {m['event_id']} in {journal_path(args)}")
    return 0


def cmd_restore(args):
    path, conn, m, note = open_for_write(args)
    entries = journal_for(args, note["id"])
    if args.undo_id:
        entries = [e for e in entries if e["undo_id"] == args.undo_id]
    if not entries:
        raise CliError(f"no undo entry for {m['event_id']}" + (f" with id {args.undo_id}" if args.undo_id else "")
                       + "; run `history` to list them", EXIT_NOT_FOUND)
    row = entries[-1]["row"]
    # Only the columns write-notes touches go back; enhanced_content belongs to the app's
    # enhancer and may have been regenerated since, so the journal keeps it for reference only.
    values = {"content": row.get("content") or "", "timestamp": row.get("timestamp"),
              "last_manual_edit": row.get("last_manual_edit")}
    return guarded_update(args, path, conn, m, note, values, "restore")


# ---------------------------------------------------------------- argv

def build_parser():
    p = argparse.ArgumentParser(prog="foresight", description=__doc__.split("\n\n")[0])
    p.add_argument("--db", help="database path (default: $FORESIGHT_DB or the app's own database)")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    window = argparse.ArgumentParser(add_help=False)
    g = window.add_mutually_exclusive_group()
    g.add_argument("--today", action="store_true")
    g.add_argument("--yesterday", action="store_true")
    g.add_argument("--date", metavar="YYYY-MM-DD")
    g.add_argument("--since", metavar="YYYY-MM-DD", help="inclusive; pair with --until")
    window.add_argument("--until", metavar="YYYY-MM-DD", help="inclusive")
    window.add_argument("--name", help="case-insensitive title substring")
    window.add_argument("--transcribed", action="store_true", help="only meetings with a transcript")

    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor", parents=[common], help="check database, schema, and app state").set_defaults(fn=cmd_doctor)
    s = sub.add_parser("meetings", parents=[common, window], help="list meetings, oldest first")
    s.add_argument("--limit", type=int, help="keep only the N most recent")
    s.set_defaults(fn=cmd_meetings)
    s = sub.add_parser("show", parents=[common], help="metadata, app summary, notes, enhanced notes")
    s.add_argument("ref", help="event_id, note id, or unique title substring")
    s.set_defaults(fn=cmd_show)
    s = sub.add_parser("transcript", parents=[common], help="full transcript")
    s.add_argument("ref")
    s.add_argument("--with-summary", action="store_true", help="append the app's own summary")
    s.set_defaults(fn=cmd_transcript)
    s = sub.add_parser("notes", parents=[common], help="the user's notes (or --enhanced)")
    s.add_argument("ref")
    s.add_argument("--enhanced", action="store_true", help="the app-generated enhanced notes instead")
    s.set_defaults(fn=cmd_notes)
    s = sub.add_parser("search", parents=[common, window], help="substring search across meetings")
    s.add_argument("query")
    s.add_argument("--context", type=int, default=80, help="characters of context each side")
    s.add_argument("--limit", type=int, default=50)
    s.set_defaults(fn=cmd_search)
    guards = argparse.ArgumentParser(add_help=False)
    guards.add_argument("--expect-sha256", required=True,
                        help="content_sha256 from `notes REF --json`; refuses if the notes changed since")
    guards.add_argument("--dry-run", action="store_true", help="run every guard, write nothing")
    guards.add_argument("--allow-app-running", action="store_true",
                        help="write while Foresight runs (confirm the meeting is not open or recording first)")
    guards.add_argument("--ignore-recent-activity", action="store_true",
                        help="skip the recently-written-database check")
    guards.add_argument("--full-backup", action="store_true",
                        help="also copy the whole database (tens of MB) to the state dir first")
    state = argparse.ArgumentParser(add_help=False)
    state.add_argument("--state-dir", help=f"undo journal location (default: $FORESIGHT_STATE_DIR or {DEFAULT_STATE_DIR})")

    s = sub.add_parser("write-notes", parents=[common, guards, state], help="replace (or --append to) a meeting's notes")
    s.add_argument("ref")
    s.add_argument("--file", required=True, help="markdown file to write, or - for stdin")
    s.add_argument("--append", action="store_true", help="append below the existing notes")
    s.set_defaults(fn=cmd_write_notes)
    s = sub.add_parser("history", parents=[common, state], help="undo journal entries for a meeting's notes")
    s.add_argument("ref")
    s.set_defaults(fn=cmd_history)
    s = sub.add_parser("restore", parents=[common, guards, state], help="put a journaled prior version back")
    s.add_argument("ref")
    s.add_argument("--undo-id", help="entry from `history` (default: the most recent for this note)")
    s.set_defaults(fn=cmd_restore)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.fn(args)
    except CliError as exc:
        print(f"foresight: {exc}", file=sys.stderr)
        return exc.code
    except sqlite3.Error as exc:
        print(f"foresight: sqlite error: {exc}", file=sys.stderr)
        return EXIT_RUNTIME
    finally:
        while OPEN_CONNECTIONS:
            OPEN_CONNECTIONS.pop().close()


if __name__ == "__main__":
    sys.exit(main())
