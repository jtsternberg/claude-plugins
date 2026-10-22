#!/usr/bin/env python3
"""Tests for foresight.py against a synthetic fixture database.

The fixture is built from tests/fixtures/schema.sql (the app's real DDL, no data) and
filled with invented meetings. Nothing here opens the user's live Foresight database:
every case passes --db, and setUp points FORESIGHT_DB and FORESIGHT_STATE_DIR into a
temporary directory so a forgotten flag still cannot reach it.

  python3 -m unittest discover -s tests
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "foresight.py"
SCHEMA = (HERE / "fixtures" / "schema.sql").read_text()

spec = importlib.util.spec_from_file_location("foresight", SCRIPT)
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)


def ms(dt):
    return int(dt.timestamp() * 1000)


def transcript(*segments):
    return json.dumps([{"segment_title": title, "duration_seconds": secs,
                        "turns": [{"speaker": s, "text": t} for s, t in turns]}
                       for title, secs, turns in segments])


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


TODAY_10 = datetime.now().replace(hour=10, minute=0, second=0, microsecond=0)
LAST_WEEK = TODAY_10 - timedelta(days=7)


def build_db(path, schema=SCHEMA):
    conn = sqlite3.connect(path)
    conn.executescript(schema)
    conn.execute("PRAGMA user_version = 5")
    standup = f"event_{ms(TODAY_10)}"
    conn.execute("INSERT INTO event_transcript_table VALUES (?,?,?,?,?,?,?)", (
        standup, ms(TODAY_10), "Daily Standup",
        transcript(("Transcript 10:00", 900, [
            ("Microphone", "Morning all."), ("Microphone", "The widget release slipped."),
            ("Remote", "We can ship the widget on Friday."), ("Remote", ""),
        ])),
        "# Overview\nRelease moved to Friday.", standup, "alex@example.com, sam@example.com"))
    conn.execute("INSERT INTO notes_table VALUES (?,?,?,?,?,?,?,?)", (
        f"note_{standup}", "Daily Standup", "- widget release", "Enhanced: widget ships Friday",
        ms(TODAY_10), None, None, 2))
    # A calendar-linked meeting from last week, recorded across two segments, no summary.
    cal = "abc123calendarid_" + LAST_WEEK.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    conn.execute("INSERT INTO event_transcript_table VALUES (?,?,?,?,?,?,?)", (
        cal, ms(LAST_WEEK), "Planning Sync",
        transcript(("Transcript 10:00", 1800, [("Remote", "Budget review first.")]),
                   ("Transcript 10:30", 600, [("Microphone", "Then the roadmap.")])),
        "", cal, None))
    conn.execute("INSERT INTO notes_table VALUES (?,?,?,?,?,?,?,?)", (
        f"note_{cal}", "Planning Sync (renamed)", "", None, ms(LAST_WEEK), None, None, 2))
    # A note with no transcript, as the app leaves for a meeting it never recorded.
    empty = f"event_{ms(TODAY_10 + timedelta(hours=3))}"
    conn.execute("INSERT INTO notes_table VALUES (?,?,?,?,?,?,?,?)", (
        f"note_{empty}", "[New Meeting]", "", None, ms(TODAY_10 + timedelta(hours=3)), None, None, 2))
    # A transcript the app never gave a notes row.
    orphan = f"event_{ms(TODAY_10 + timedelta(hours=1))}"
    conn.execute("INSERT INTO event_transcript_table VALUES (?,?,?,?,?,?,?)", (
        orphan, ms(TODAY_10 + timedelta(hours=1)), "Orphan Call",
        transcript(("Transcript 11:00", 60, [("Remote", "hello")])), None, None, None))
    conn.commit()
    conn.close()
    return {"standup": standup, "cal": cal, "empty": empty, "orphan": orphan}


def fs_main_quiet(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = fs.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        root = Path(self.tmp.name)
        self.db = root / "database.sqlite"
        self.state = root / "state"
        self.ids = build_db(self.db)
        self.idle()
        patches = [
            mock.patch.dict(os.environ, {"FORESIGHT_DB": str(self.db), "FORESIGHT_STATE_DIR": str(self.state)}),
            mock.patch.object(fs, "app_running", return_value=False),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)
        self.assertNotEqual(self.db, fs.DEFAULT_DB)

    def idle(self):
        """Age the fixture's mtime so the recent-activity guard fires only where a test asks."""
        past = time.time() - 3600
        os.utime(self.db, (past, past))

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fs.main(["--db", str(self.db), *argv])
        return code, out.getvalue(), err.getvalue()

    def json_cli(self, *argv):
        code, out, err = self.run_cli(*argv, "--json")
        self.assertEqual(code, 0, err)
        return json.loads(out)

    def content(self, event_id):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute("SELECT content FROM notes_table WHERE id = ?", (f"note_{event_id}",)).fetchone()[0]
        finally:
            conn.close()

    def write(self, event_id, text, *extra, expect=None):
        f = Path(self.tmp.name) / "draft.md"
        f.write_text(text)
        expect = expect or sha(self.content(event_id))
        if "--ignore-recent-activity" not in extra and not getattr(self, "keep_mtime", False):
            self.idle()
        return self.run_cli("write-notes", event_id, "--file", str(f), "--expect-sha256", expect, *extra)


class ReadTests(Base):
    def test_meetings_today_excludes_last_week(self):
        titles = [m["title"] for m in self.json_cli("meetings", "--today")]
        self.assertIn("Daily Standup", titles)
        self.assertNotIn("Planning Sync (renamed)", titles)

    def test_transcribed_filter_drops_note_only_meetings(self):
        titles = [m["title"] for m in self.json_cli("meetings", "--today", "--transcribed")]
        self.assertEqual(titles, ["Daily Standup", "Orphan Call"])

    def test_notes_title_wins_over_transcript_event_name(self):
        m = self.json_cli("meetings", "--name", "planning")[0]
        self.assertEqual(m["title"], "Planning Sync (renamed)")
        self.assertEqual(m["duration_seconds"], 2400)

    def test_date_and_range_filters(self):
        day = LAST_WEEK.date().isoformat()
        self.assertEqual(len(self.json_cli("meetings", "--date", day)), 1)
        since = (LAST_WEEK - timedelta(days=1)).date().isoformat()
        self.assertEqual(len(self.json_cli("meetings", "--since", since, "--until", day)), 1)

    def test_note_only_meeting_dates_from_event_id(self):
        m = self.json_cli("meetings", "--name", "new meeting")[0]
        self.assertFalse(m["has_transcript"])
        self.assertTrue(m["started_at"].startswith(TODAY_10.date().isoformat()))

    def test_calendar_id_start_is_parsed(self):
        start = fs.event_id_start("x_20261012T150000Z")
        self.assertEqual(datetime.fromtimestamp(start / 1000, timezone.utc).hour, 15)

    def test_transcript_merges_consecutive_speaker_turns(self):
        code, out, _ = self.run_cli("transcript", self.ids["standup"])
        self.assertEqual(code, 0)
        self.assertIn("[Microphone] Morning all. The widget release slipped.", out)
        self.assertIn("[Remote] We can ship the widget on Friday.", out)
        self.assertIn("attendees: alex@example.com, sam@example.com", out)

    def test_transcript_json_keeps_raw_segments(self):
        data = self.json_cli("transcript", self.ids["cal"])
        self.assertEqual(len(data["segments"]), 2)
        self.assertIsNone(data["summary"] or None)

    def test_show_includes_summary_notes_and_hash(self):
        data = self.json_cli("show", "standup")
        self.assertEqual(data["summary"], "# Overview\nRelease moved to Friday.")
        self.assertEqual(data["notes_sha256"], sha("- widget release"))
        self.assertEqual(data["enhanced_notes"], "Enhanced: widget ships Friday")

    def test_notes_and_enhanced(self):
        self.assertEqual(self.json_cli("notes", self.ids["standup"])["content"], "- widget release")
        enhanced = self.json_cli("notes", self.ids["standup"], "--enhanced")
        self.assertEqual(enhanced["content"], "Enhanced: widget ships Friday")
        self.assertEqual(enhanced["content_sha256"], sha("- widget release"))

    def test_resolve_by_note_id(self):
        self.assertEqual(self.json_cli("show", f"note_{self.ids['standup']}")["title"], "Daily Standup")

    def test_ambiguous_and_missing_refs_exit_4(self):
        code, _, err = self.run_cli("show", "s")
        self.assertEqual(code, 4)
        self.assertIn("pass an event_id", err)
        self.assertEqual(self.run_cli("show", "no such meeting")[0], 4)

    def test_search_finds_across_fields_with_speaker(self):
        hits = self.json_cli("search", "widget")
        fields = {(h["field"], h["speaker"]) for h in hits}
        self.assertIn(("transcript", "Microphone"), fields)
        self.assertIn(("transcript", "Remote"), fields)
        self.assertIn(("notes", None), fields)
        self.assertIn(("enhanced_notes", None), fields)

    def test_search_respects_date_window(self):
        self.assertEqual(self.json_cli("search", "budget", "--today"), [])
        self.assertEqual(len(self.json_cli("search", "budget")), 1)

    def test_reads_leave_database_bytes_untouched(self):
        before = self.db.read_bytes()
        for argv in (["meetings"], ["show", "standup"], ["transcript", "standup"], ["search", "widget"],
                     ["notes", "standup"], ["doctor"]):
            self.run_cli(*argv)
        self.assertEqual(self.db.read_bytes(), before)


class SchemaTests(Base):
    def rebuild(self, schema):
        self.db.unlink()
        conn = sqlite3.connect(self.db)
        conn.executescript(schema)
        conn.close()

    def test_missing_column_fails_clearly(self):
        self.rebuild(SCHEMA.replace('"enhanced_content" TEXT NULL, ', ""))
        code, _, err = self.run_cli("meetings")
        self.assertEqual(code, 3)
        self.assertIn("notes_table lacks column(s): enhanced_content", err)

    def test_missing_table_fails_clearly(self):
        self.rebuild("\n".join(l for l in SCHEMA.splitlines() if "event_transcript_table" not in l))
        code, _, err = self.run_cli("transcript", "x")
        self.assertEqual(code, 3)
        self.assertIn("missing table event_transcript_table", err)

    def test_doctor_reports_mismatch_with_exit_3(self):
        self.rebuild(SCHEMA.replace('"attendees" TEXT NULL', '"guests" TEXT NULL'))
        code, out, _ = self.run_cli("doctor")
        self.assertEqual(code, 3)
        self.assertIn("attendees", out)

    def test_unexpected_transcript_format_fails_clearly(self):
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE event_transcript_table SET transcript = 'plain text' WHERE event_id = ?",
                     (self.ids["standup"],))
        conn.commit()
        conn.close()
        code, _, err = self.run_cli("transcript", self.ids["standup"])
        self.assertEqual(code, 3)
        self.assertIn("transcript format changed", err)

    def set_user_version(self, v):
        conn = sqlite3.connect(self.db)
        conn.execute(f"PRAGMA user_version = {v}")
        conn.close()
        self.idle()

    def test_untested_user_version_refuses_writes_and_restores(self):
        eid = self.ids["standup"]
        f = Path(self.tmp.name) / "d.md"
        f.write_text("x")
        self.set_user_version(6)
        for argv in (["write-notes", eid, "--file", str(f)], ["restore", eid]):
            code, _, err = self.run_cli(*argv, "--expect-sha256", sha("- widget release"))
            self.assertEqual(code, 5, argv)
            self.assertIn("--allow-untested-schema", err)
        code, _, err = self.run_cli("write-notes", eid, "--file", str(f), "--expect-sha256",
                                    sha("- widget release"), "--allow-untested-schema")
        self.assertEqual(code, 0, err)
        self.idle()
        code, _, err = self.run_cli("restore", eid, "--expect-sha256", sha("x"), "--allow-untested-schema")
        self.assertEqual(code, 0, err)

    def test_untested_user_version_warns_but_works(self):
        conn = sqlite3.connect(self.db)
        conn.execute("PRAGMA user_version = 6")
        conn.close()
        code, _, err = self.run_cli("meetings")
        self.assertEqual(code, 0)
        self.assertIn("untested", err)

    def test_locked_database_read_says_retry(self):
        hold = sqlite3.connect(self.db, isolation_level=None)
        hold.execute("BEGIN EXCLUSIVE")
        self.addCleanup(hold.close)
        with mock.patch.object(fs, "BUSY_TIMEOUT_SECONDS", 0.05):
            code, _, err = self.run_cli("meetings")
        self.assertEqual(code, 1)
        self.assertIn("retry", err)

    def test_missing_database(self):
        self.db.unlink()
        code, _, err = self.run_cli("meetings")
        self.assertEqual(code, 1)
        self.assertIn("not found", err)


class WriteTests(Base):
    def journal(self):
        path = self.state / "undo.jsonl"
        return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []

    def test_replace_writes_verifies_and_journals_prior_row(self):
        code, out, err = self.write(self.ids["standup"], "# Notes\n- shipped Friday\n", "--json")
        self.assertEqual(code, 0, err)
        result = json.loads(out)
        self.assertTrue(result["verified"])
        self.assertEqual(self.content(self.ids["standup"]), "# Notes\n- shipped Friday\n")
        entry = self.journal()[-1]
        self.assertEqual(entry["undo_id"], result["undo_id"])
        self.assertEqual(entry["row"]["content"], "- widget release")
        self.assertEqual(entry["row"]["enhanced_content"], "Enhanced: widget ships Friday")
        self.assertIn("last_manual_edit", entry["row"])

    def test_write_sets_timestamp_and_last_manual_edit(self):
        before = int(time.time() * 1000)
        self.assertEqual(self.write(self.ids["standup"], "x")[0], 0)
        conn = sqlite3.connect(self.db)
        ts, edit = conn.execute("SELECT timestamp, last_manual_edit FROM notes_table WHERE id = ?",
                                (f"note_{self.ids['standup']}",)).fetchone()
        conn.close()
        self.assertGreaterEqual(ts, before)
        self.assertEqual(ts, edit)

    def test_no_full_database_copy_by_default(self):
        self.write(self.ids["standup"], "x")
        self.assertFalse((self.state / "full-backups").exists())
        self.assertEqual([p.name for p in self.state.iterdir()], ["undo.jsonl"])

    def test_full_backup_only_with_flag(self):
        code, out, _ = self.write(self.ids["standup"], "x", "--full-backup", "--json")
        self.assertEqual(code, 0)
        backup = Path(json.loads(out)["full_backup"])
        conn = sqlite3.connect(backup)
        self.assertEqual(conn.execute("SELECT content FROM notes_table WHERE id = ?",
                                      (f"note_{self.ids['standup']}",)).fetchone()[0], "- widget release")
        conn.close()

    def test_append_keeps_existing_notes(self):
        self.write(self.ids["standup"], "## Action items\n- Sam: ship", "--append")
        self.assertEqual(self.content(self.ids["standup"]), "- widget release\n\n## Action items\n- Sam: ship")

    def test_stale_hash_refuses_and_writes_nothing(self):
        code, _, err = self.write(self.ids["standup"], "x", expect=sha("something else"))
        self.assertEqual(code, 5)
        self.assertIn("changed since you read them", err)
        self.assertEqual(self.content(self.ids["standup"]), "- widget release")
        self.assertEqual(self.journal(), [])

    def test_app_running_refuses_without_flag(self):
        with mock.patch.object(fs, "app_running", return_value=True):
            code, _, err = self.write(self.ids["standup"], "x")
            self.assertEqual(code, 5)
            self.assertIn("--allow-app-running", err)
            self.assertEqual(self.write(self.ids["standup"], "x", "--allow-app-running")[0], 0)

    def test_recent_database_activity_refuses_while_app_runs(self):
        self.keep_mtime = True
        os.utime(self.db, None)
        with mock.patch.object(fs, "app_running", return_value=True):
            code, _, err = self.write(self.ids["standup"], "x", "--allow-app-running")
            self.assertEqual(code, 5)
            self.assertIn("likely recording", err)
            code, _, _ = self.write(self.ids["standup"], "x", "--allow-app-running", "--ignore-recent-activity")
            self.assertEqual(code, 0)

    def test_recent_activity_refuses_even_when_app_is_not_running(self):
        self.keep_mtime = True
        os.utime(self.db, None)
        self.assertEqual(self.write(self.ids["standup"], "x")[0], 5)
        self.assertEqual(self.write(self.ids["standup"], "x", "--ignore-recent-activity")[0], 0)

    def test_dry_run_writes_nothing_and_journals_nothing(self):
        code, out, _ = self.write(self.ids["standup"], "x", "--dry-run", "--json")
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(out)["dry_run"])
        self.assertEqual(self.content(self.ids["standup"]), "- widget release")
        self.assertFalse(self.state.exists())

    def test_refuses_meeting_without_notes_row(self):
        f = Path(self.tmp.name) / "d.md"
        f.write_text("x")
        code, _, err = self.run_cli("write-notes", self.ids["orphan"], "--file", str(f), "--expect-sha256", sha(""))
        self.assertEqual(code, 5)
        self.assertIn("never inserts rows", err)

    def test_refuses_empty_notes(self):
        self.assertEqual(self.write(self.ids["standup"], "  \n")[0], 5)

    def test_unverified_write_exits_6(self):
        real = fs.read_note
        calls = {"n": 0}

        def flaky(conn, note_id):
            calls["n"] += 1
            row = real(conn, note_id)
            return None if calls["n"] > 1 else row

        with mock.patch.object(fs, "read_note", side_effect=flaky):
            code, _, err = self.write(self.ids["standup"], "x")
        self.assertEqual(code, 6)
        self.assertIn("restore", err)

    def test_journal_is_capped(self):
        eid = self.ids["standup"]
        for i in range(fs.JOURNAL_KEPT + 5):
            self.assertEqual(self.write(eid, f"v{i}")[0], 0)
        entries = self.journal()
        self.assertEqual(len(entries), fs.JOURNAL_KEPT)
        self.assertEqual(entries[-1]["row"]["content"], f"v{fs.JOURNAL_KEPT + 3}")

    def test_journal_limit_env_override(self):
        eid = self.ids["standup"]
        with mock.patch.dict(os.environ, {"FORESIGHT_UNDO_LIMIT": "3"}):
            for i in range(5):
                self.assertEqual(self.write(eid, f"v{i}")[0], 0)
        self.assertEqual([e["row"]["content"] for e in self.journal()], ["v1", "v2", "v3"])

    def test_journal_limit_env_must_be_positive_int(self):
        for bad in ("0", "-2", "ten"):
            with mock.patch.dict(os.environ, {"FORESIGHT_UNDO_LIMIT": bad}):
                code, _, err = self.write(self.ids["standup"], "x")
            self.assertEqual(code, 2, bad)
            self.assertIn("FORESIGHT_UNDO_LIMIT", err)
        self.assertEqual(self.content(self.ids["standup"]), "- widget release")
        self.assertEqual(self.journal(), [])

    def test_journal_is_private(self):
        self.write(self.ids["standup"], "x")
        self.assertEqual((self.state / "undo.jsonl").stat().st_mode & 0o777, 0o600)

    def test_state_dir_and_full_backups_are_private_even_if_dir_preexisted(self):
        (self.state / "full-backups").mkdir(parents=True)
        os.chmod(self.state, 0o755)
        os.chmod(self.state / "full-backups", 0o755)
        old = self.state / "full-backups" / "database-old.sqlite"
        old.write_text("")
        os.chmod(old, 0o644)
        code, out, err = self.write(self.ids["standup"], "x", "--full-backup", "--json")
        self.assertEqual(code, 0, err)
        mode = lambda p: p.stat().st_mode & 0o777
        self.assertEqual(mode(self.state), 0o700)
        self.assertEqual(mode(self.state / "full-backups"), 0o700)
        self.assertEqual(mode(Path(json.loads(out)["full_backup"])), 0o600)
        self.assertEqual(mode(old), 0o600)

    def test_missing_file_exits_cleanly(self):
        code, _, err = self.run_cli("write-notes", self.ids["standup"], "--file", "/nonexistent/draft.md",
                                    "--expect-sha256", sha("- widget release"))
        self.assertEqual(code, 2)
        self.assertIn("/nonexistent/draft.md", err)
        self.assertNotIn("Traceback", err)

    def test_busy_database_refuses_says_nothing_written_and_leaves_no_undo_entry(self):
        hold = sqlite3.connect(self.db, isolation_level=None)
        hold.execute("BEGIN IMMEDIATE")
        self.addCleanup(hold.close)
        with mock.patch.object(fs, "BUSY_TIMEOUT_SECONDS", 0.05):
            code, _, err = self.write(self.ids["standup"], "x")
        self.assertEqual(code, 5)
        self.assertIn("nothing written", err)
        hold.execute("ROLLBACK")
        self.assertEqual(self.content(self.ids["standup"]), "- widget release")
        self.assertEqual(self.journal(), [])

    def test_change_inside_transaction_leaves_no_undo_entry(self):
        real = fs.check_app_quiet

        def edit_then_check(args, path):
            conn = sqlite3.connect(self.db)
            conn.execute("UPDATE notes_table SET content = 'app edit' WHERE id = ?", (f"note_{self.ids['standup']}",))
            conn.commit()
            conn.close()
            self.idle()
            return real(args, path)

        with mock.patch.object(fs, "check_app_quiet", side_effect=edit_then_check):
            code, _, err = self.write(self.ids["standup"], "x")
        self.assertEqual(code, 5)
        self.assertIn("nothing written", err)
        self.assertEqual(self.content(self.ids["standup"]), "app edit")
        self.assertEqual(self.journal(), [])


class RestoreTests(Base):
    def restore(self, eid, *extra):
        self.idle()
        return self.run_cli("restore", eid, "--expect-sha256", sha(self.content(eid)), *extra)

    def test_restore_puts_prior_version_back_and_is_itself_undoable(self):
        eid = self.ids["standup"]
        self.write(eid, "draft one")
        code, _, err = self.restore(eid)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.content(eid), "- widget release")
        history = self.json_cli("history", eid)
        self.assertEqual([h["action"] for h in history], ["replace", "restore"])
        self.assertEqual(history[-1]["prior_sha256"], sha("draft one"))

    def test_restore_steps_back_one_entry_at_a_time(self):
        eid = self.ids["standup"]
        self.write(eid, "one")
        self.write(eid, "two")
        first = self.json_cli("history", eid)[0]["undo_id"]
        self.assertEqual(self.restore(eid)[0], 0)
        self.assertEqual(self.content(eid), "one")
        self.assertEqual(self.restore(eid, "--undo-id", first)[0], 0)
        self.assertEqual(self.content(eid), "- widget release")

    def test_restore_jumping_past_a_later_write_needs_force(self):
        eid = self.ids["standup"]
        self.write(eid, "one")
        self.write(eid, "two")
        first = self.json_cli("history", eid)[0]["undo_id"]
        code, _, err = self.restore(eid, "--undo-id", first)
        self.assertEqual(code, 5)
        self.assertIn("--force", err)
        self.assertEqual(self.content(eid), "two")
        self.assertEqual(self.restore(eid, "--undo-id", first, "--force")[0], 0)
        self.assertEqual(self.content(eid), "- widget release")

    def test_restore_refuses_when_notes_edited_since_the_write(self):
        eid = self.ids["standup"]
        self.write(eid, "one")
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE notes_table SET content = 'user typed more' WHERE id = ?", (f"note_{eid}",))
        conn.commit()
        conn.close()
        code, _, err = self.restore(eid)
        self.assertEqual(code, 5)
        self.assertIn("--force", err)
        self.assertEqual(self.content(eid), "user typed more")

    def test_restore_refuses_entry_whose_write_never_landed(self):
        eid = self.ids["standup"]
        args = fs.build_parser().parse_args(["history", eid])
        fs.append_journal(args, {"undo_id": "1-crash", "saved_at": "x", "action": "replace",
                                 "db": os.path.realpath(self.db), "event_id": eid,
                                 "row": {"id": f"note_{eid}", "content": "older", "timestamp": 1,
                                         "last_manual_edit": None},
                                 "replaced_by_sha256": sha("never committed")})
        code, _, err = self.restore(eid)
        self.assertEqual(code, 5)
        self.assertEqual(self.content(eid), "- widget release")

    def test_history_and_restore_ignore_entries_from_another_database(self):
        eid = self.ids["standup"]
        copy = Path(self.tmp.name) / "copy.sqlite"
        shutil.copy(self.db, copy)
        past = time.time() - 3600
        os.utime(copy, (past, past))
        f = Path(self.tmp.name) / "d.md"
        f.write_text("copy content")
        code, _, err = fs_main_quiet("--db", str(copy), "write-notes", eid, "--file", str(f),
                                     "--expect-sha256", sha("- widget release"))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.json_cli("history", eid), [])
        self.assertEqual(self.restore(eid)[0], 4)
        self.assertEqual(self.content(eid), "- widget release")

    def test_journal_matches_database_through_a_symlink(self):
        eid = self.ids["standup"]
        self.write(eid, "one")
        link = Path(self.tmp.name) / "link.sqlite"
        link.symlink_to(self.db)
        code, out, err = fs_main_quiet("--db", str(link), "history", eid, "--json")
        self.assertEqual(code, 0, err)
        self.assertEqual(len(json.loads(out)), 1)

    def test_restore_leaves_enhanced_content_alone(self):
        eid = self.ids["standup"]
        self.write(eid, "one")
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE notes_table SET enhanced_content = 'regenerated' WHERE id = ?", (f"note_{eid}",))
        conn.commit()
        conn.close()
        self.restore(eid)
        self.assertEqual(self.json_cli("notes", eid, "--enhanced")["content"], "regenerated")

    def test_restore_without_journal_exits_4(self):
        code, _, err = self.restore(self.ids["standup"])
        self.assertEqual(code, 4)
        self.assertIn("history", err)

    def test_restore_honors_the_same_guards(self):
        eid = self.ids["standup"]
        self.write(eid, "one")
        with mock.patch.object(fs, "app_running", return_value=True):
            self.assertEqual(self.restore(eid)[0], 5)
        self.assertEqual(self.content(eid), "one")


class SubprocessTests(Base):
    def test_cli_runs_standalone(self):
        env = {**os.environ, "FORESIGHT_APP_PROCESS": "no-such-process-foresight-test"}
        out = subprocess.run([sys.executable, str(SCRIPT), "--db", str(self.db), "meetings", "--json"],
                             capture_output=True, text=True, env=env)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(len(json.loads(out.stdout)), 4)


if __name__ == "__main__":
    unittest.main()
