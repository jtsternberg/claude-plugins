#!/usr/bin/env python3
"""Tests for runway.py and install-hooks.py.

No network, no real home directory: in-process tests point the scripts' CLAUDE_DIR and
STATE_FILE at a temporary tree and stub the credential read wherever they reach collect(), and
subprocess tests run under a temporary HOME that holds no credentials.

  python3 tests/test_runway.py            # or: python3 -m unittest discover -s tests
"""

import importlib.util
import io
import json
import os
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def load(name, filename):
    """Import a script by path, since neither file is on the module search path."""
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rw = load("runway", "runway.py")
ih = load("install_hooks", "install-hooks.py")

RUNWAY_ENV = ("RUNWAY_CONTEXT_LIMIT", "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
              "RUNWAY_CONTEXT_NOTICE", "RUNWAY_CONTEXT_WRAP_UP", "RUNWAY_CONTEXT_STOP",
              "RUNWAY_QUOTA_NOTICE", "RUNWAY_QUOTA_WRAP_UP", "RUNWAY_QUOTA_STOP", "RUNWAY_STOP_WORK")


class Sandboxed(unittest.TestCase):
    """Base case: a throwaway CLAUDE_DIR, a clean environment, and a fixed timezone."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.home = Path(self.tmp.name)
        patches = [
            mock.patch.object(rw, "CLAUDE_DIR", self.home),
            mock.patch.object(rw, "STATE_FILE", self.home / "runway" / "state.json"),
            mock.patch.dict(os.environ, {k: "" for k in RUNWAY_ENV}, clear=False),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        for key in RUNWAY_ENV:
            os.environ.pop(key, None)
        self.addCleanup(self.tmp.cleanup)

    def write_settings(self, payload):
        """Drop a settings.json into the sandboxed home."""
        (self.home / "settings.json").write_text(json.dumps(payload))

    def write_transcript(self, session_id, lines, cwd="/tmp/proj"):
        """Write a transcript for a session and return its path."""
        directory = self.home / "projects" / rw.project_slug(cwd)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{session_id}.jsonl"
        path.write_text("\n".join(lines) + "\n")
        return path

    @staticmethod
    def assistant_turn(model, cache_read=0, cache_creation=0, fresh=0, output=0):
        """Build one assistant transcript line with the usage block the script reads."""
        return json.dumps({"type": "assistant", "message": {
            "model": model,
            "usage": {"input_tokens": fresh, "cache_read_input_tokens": cache_read,
                      "cache_creation_input_tokens": cache_creation, "output_tokens": output},
        }})


class LimitForModel(Sandboxed):

    def test_1m_marker_wins(self):
        self.assertEqual(rw.limit_for_model("claude-opus-5[1m]"), rw.LARGE_CONTEXT_LIMIT)

    def test_marker_beats_a_small_family_name(self):
        self.assertEqual(rw.limit_for_model("claude-haiku-4-5[1m]"), rw.LARGE_CONTEXT_LIMIT)

    def test_haiku_is_small(self):
        self.assertEqual(rw.limit_for_model("claude-haiku-4-5-20251001"),
                         rw.SMALL_CONTEXT_LIMIT)

    def test_legacy_families_are_small(self):
        self.assertEqual(rw.limit_for_model("claude-3-5-sonnet-20241022"),
                         rw.SMALL_CONTEXT_LIMIT)

    def test_case_is_ignored(self):
        self.assertEqual(rw.limit_for_model("CLAUDE-HAIKU-4-5"), rw.SMALL_CONTEXT_LIMIT)

    def test_unknown_model_is_large(self):
        self.assertEqual(rw.limit_for_model("claude-something-new"), rw.LARGE_CONTEXT_LIMIT)

    def test_empty_is_unknown_not_large(self):
        self.assertIsNone(rw.limit_for_model(""))

    def test_none_is_unknown(self):
        self.assertIsNone(rw.limit_for_model(None))


class ResolveContextLimit(Sandboxed):

    def test_explicit_override_beats_everything(self):
        os.environ["RUNWAY_CONTEXT_LIMIT"] = "123456"
        self.assertEqual(rw.resolve_context_limit(50_000, None, "claude-opus-5[1m]"), 50_000)

    def test_runway_env_beats_the_claude_env(self):
        os.environ["RUNWAY_CONTEXT_LIMIT"] = "300000"
        os.environ["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = "400000"
        self.assertEqual(rw.resolve_context_limit(None, None, "claude-haiku-4-5"), 300_000)

    def test_claude_env_beats_the_model(self):
        os.environ["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = "400000"
        self.assertEqual(rw.resolve_context_limit(None, None, "claude-opus-5[1m]"), 400_000)

    def test_model_beats_the_settings_file(self):
        self.write_settings({"model": "claude-opus-5[1m]"})
        self.assertEqual(rw.resolve_context_limit(None, None, "claude-haiku-4-5"),
                         rw.SMALL_CONTEXT_LIMIT)

    def test_settings_used_when_the_model_is_unknown(self):
        self.write_settings({"model": "claude-haiku-4-5"})
        self.assertEqual(rw.resolve_context_limit(None, None, None), rw.SMALL_CONTEXT_LIMIT)

    def test_falls_back_to_one_million(self):
        self.assertEqual(rw.resolve_context_limit(None, None, None), rw.LARGE_CONTEXT_LIMIT)

    def test_widens_when_usage_already_exceeds_the_guess(self):
        self.assertEqual(rw.resolve_context_limit(None, 250_000, "claude-haiku-4-5"),
                         rw.LARGE_CONTEXT_LIMIT)

    def test_does_not_widen_at_exactly_the_limit(self):
        self.assertEqual(rw.resolve_context_limit(None, rw.SMALL_CONTEXT_LIMIT,
                                                  "claude-haiku-4-5"),
                         rw.SMALL_CONTEXT_LIMIT)

    def test_junk_env_is_ignored(self):
        os.environ["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = "lots"
        self.assertEqual(rw.env_context_limit(), 0)
        self.assertEqual(rw.resolve_context_limit(None, None, "claude-haiku-4-5"),
                         rw.SMALL_CONTEXT_LIMIT)

    def test_negative_env_is_ignored(self):
        os.environ["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = "-1"
        self.assertEqual(rw.env_context_limit(), 0)

    def test_unreadable_settings_do_not_raise(self):
        (self.home / "settings.json").write_text("{ not json")
        self.assertIsNone(rw.configured_context_limit())

    def test_settings_without_a_model_key(self):
        self.write_settings({"hooks": {}})
        self.assertIsNone(rw.configured_context_limit())

    def test_local_settings_win_over_shared(self):
        self.write_settings({"model": "claude-opus-5[1m]"})
        (self.home / "settings.local.json").write_text(json.dumps({"model": "claude-haiku-4-5"}))
        self.assertEqual(rw.configured_context_limit(), rw.SMALL_CONTEXT_LIMIT)


class HookPayload(Sandboxed):

    def read_with(self, text):
        """Run hook_payload against a fake non-tty stdin holding `text`."""
        with mock.patch.object(rw.sys, "stdin", io.StringIO(text)):
            return rw.hook_payload(wait=0)

    def test_reads_a_json_object(self):
        self.assertEqual(self.read_with('{"hook_event_name":"SessionStart"}'),
                         {"hook_event_name": "SessionStart"})

    def test_empty_stdin_is_not_an_error(self):
        self.assertEqual(self.read_with(""), {})

    def test_malformed_json_is_not_an_error(self):
        self.assertEqual(self.read_with("{oops"), {})

    def test_a_json_list_is_rejected(self):
        self.assertEqual(self.read_with("[1, 2, 3]"), {})

    def test_a_tty_is_never_read(self):
        stdin = mock.Mock()
        stdin.isatty.return_value = True
        with mock.patch.object(rw.sys, "stdin", stdin):
            self.assertEqual(rw.hook_payload(wait=0), {})
        stdin.read.assert_not_called()

    def test_missing_stdin(self):
        with mock.patch.object(rw.sys, "stdin", None):
            self.assertEqual(rw.hook_payload(wait=0), {})

    def test_a_closed_pipe_does_not_raise(self):
        read_fd, write_fd = os.pipe()
        os.close(write_fd)
        with os.fdopen(read_fd) as handle:
            with mock.patch.object(rw.sys, "stdin", handle):
                self.assertEqual(rw.hook_payload(wait=0), {})

    def test_an_idle_pipe_gives_up_instead_of_blocking(self):
        read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, write_fd)
        with os.fdopen(read_fd) as handle:
            with mock.patch.object(rw.sys, "stdin", handle):
                started = time.monotonic()
                self.assertEqual(rw.hook_payload(wait=0.2), {})
                self.assertLess(time.monotonic() - started, 2)


class ReportedModel(Sandboxed):

    def test_session_start_model(self):
        self.assertEqual(rw.reported_model({"model": "claude-opus-5[1m]"}),
                         "claude-opus-5[1m]")

    def test_post_model_switch_target(self):
        self.assertEqual(rw.reported_model({"to_model": "claude-haiku-4-5"}),
                         "claude-haiku-4-5")

    def test_model_wins_when_both_are_present(self):
        self.assertEqual(rw.reported_model({"model": "a", "to_model": "b"}), "a")

    def test_absent(self):
        self.assertIsNone(rw.reported_model({"hook_event_name": "Stop"}))

    def test_empty_string_is_not_a_model(self):
        self.assertIsNone(rw.reported_model({"model": ""}))

    def test_non_string_is_rejected(self):
        self.assertIsNone(rw.reported_model({"model": {"id": "claude-opus-5"}}))


class ModelCache(Sandboxed):

    def test_round_trip(self):
        rw.remember_model("s1", "claude-opus-5[1m]")
        self.assertEqual(rw.remembered_model("s1"), "claude-opus-5[1m]")

    def test_a_switch_replaces_the_entry(self):
        rw.remember_model("s1", "claude-opus-5[1m]")
        rw.remember_model("s1", "claude-haiku-4-5")
        self.assertEqual(rw.remembered_model("s1"), "claude-haiku-4-5")

    def test_unknown_session(self):
        self.assertIsNone(rw.remembered_model("nobody"))

    def test_no_session_id_writes_nothing(self):
        rw.remember_model(None, "claude-opus-5[1m]")
        self.assertFalse(rw.STATE_FILE.exists())

    def test_no_model_writes_nothing(self):
        rw.remember_model("s1", None)
        self.assertFalse(rw.STATE_FILE.exists())

    def test_repeat_of_the_same_value_leaves_the_file_alone(self):
        rw.remember_model("s1", "claude-opus-5[1m]")
        before = rw.STATE_FILE.stat().st_mtime_ns
        rw.remember_model("s1", "claude-opus-5[1m]")
        self.assertEqual(rw.STATE_FILE.stat().st_mtime_ns, before)

    def test_the_cache_is_capped_and_keeps_the_newest(self):
        for index in range(rw.MODEL_CACHE_SIZE + 5):
            rw.remember_model(f"s{index}", f"model-{index}")
        models = json.loads(rw.STATE_FILE.read_text())["models"]
        self.assertEqual(len(models), rw.MODEL_CACHE_SIZE)
        self.assertIn(f"s{rw.MODEL_CACHE_SIZE + 4}", models)
        self.assertNotIn("s0", models)

    def test_a_corrupt_state_file_is_survivable(self):
        rw.STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        rw.STATE_FILE.write_text("{ truncated")
        rw.remember_model("s1", "claude-opus-5[1m]")
        self.assertEqual(rw.remembered_model("s1"), "claude-opus-5[1m]")

    def test_a_non_dict_models_key_is_replaced(self):
        rw.write_raw_state({"models": ["not", "a", "dict"]})
        rw.remember_model("s1", "claude-opus-5[1m]")
        self.assertEqual(rw.remembered_model("s1"), "claude-opus-5[1m]")

    def test_write_state_preserves_every_session_keyed_map(self):
        rw.record_armed("s1", "2026-09-15 02:22", "session")
        rw.write_state({"level": "ok", "context": None, "quota": None}, "s1")
        rw.write_state({"level": "ok", "context": None, "quota": None}, "s2")
        state = json.loads(rw.STATE_FILE.read_text())
        self.assertIn("s1", state["armed"])
        self.assertEqual(set(state["throttle"]), {"s1", "s2"})

    def test_write_state_preserves_the_cache(self):
        rw.remember_model("s1", "claude-opus-5[1m]")
        rw.write_state({"level": "ok", "context": None, "quota": None})
        self.assertEqual(rw.remembered_model("s1"), "claude-opus-5[1m]")

    def test_write_state_keeps_live_keys_and_drops_snapshot_fields(self):
        rw.write_raw_state({"checked_at": 1, "level": "ok", "session": "s0",
                            "context_percent": 5, "quota_percent": 6, "models": {"s1": "m"},
                            "future": 7})
        rw.write_state({"level": "notice", "quota": {"session": {"percent": 42}},
                        "context": {"session": "s1", "percent": 81.5}}, "s1")
        state = json.loads(rw.STATE_FILE.read_text())
        self.assertEqual(set(state), {"models", "future", "throttle"})
        self.assertEqual(state["throttle"]["s1"]["quiet"], False)


class ContextReport(Sandboxed):

    def test_the_cached_model_overrides_the_transcript_id(self):
        transcript = self.write_transcript("s1", [self.assistant_turn("claude-opus-5",
                                                                      cache_read=100)])
        rw.remember_model("s1", "claude-haiku-4-5")
        report = rw.context_report(transcript, None)
        self.assertEqual((report["model"], report["api_model"], report["limit"]),
                         ("claude-haiku-4-5", "claude-opus-5", rw.SMALL_CONTEXT_LIMIT))

    def test_a_live_hook_model_beats_the_cache(self):
        transcript = self.write_transcript("s1", [self.assistant_turn("claude-opus-5",
                                                                      cache_read=100)])
        rw.remember_model("s1", "claude-haiku-4-5")
        report = rw.context_report(transcript, None, "claude-opus-5[1m]")
        self.assertEqual(report["limit"], rw.LARGE_CONTEXT_LIMIT)

    def test_tokens_sum_the_three_input_kinds_and_ignore_output(self):
        transcript = self.write_transcript("s1", [self.assistant_turn(
            "claude-opus-5[1m]", cache_read=1000, cache_creation=200, fresh=50, output=9999)])
        report = rw.context_report(transcript, None)
        self.assertEqual(report["tokens"], 1250)
        self.assertEqual(report["remaining"], rw.LARGE_CONTEXT_LIMIT - 1250)

    def test_the_newest_assistant_turn_wins(self):
        transcript = self.write_transcript("s1", [
            self.assistant_turn("claude-opus-5[1m]", cache_read=10),
            self.assistant_turn("claude-opus-5[1m]", cache_read=20),
        ])
        self.assertEqual(rw.context_report(transcript, None)["tokens"], 20)

    def test_malformed_and_userland_lines_are_skipped(self):
        transcript = self.write_transcript("s1", [
            self.assistant_turn("claude-opus-5[1m]", cache_read=10),
            json.dumps({"type": "user", "message": {"content": "hi"}}),
            "{ truncated json",
            "",
        ])
        self.assertEqual(rw.context_report(transcript, None)["tokens"], 10)

    def test_no_usage_yet_reports_nothing(self):
        transcript = self.write_transcript("s1", [json.dumps({"type": "user"})])
        self.assertIsNone(rw.context_report(transcript, None))

    def test_an_assistant_turn_without_usage_is_not_counted(self):
        transcript = self.write_transcript("s1", [
            json.dumps({"type": "assistant", "message": {"model": "claude-opus-5"}})])
        self.assertIsNone(rw.context_report(transcript, None))

    def test_level_tracks_the_thresholds(self):
        transcript = self.write_transcript("s1", [self.assistant_turn(
            "claude-haiku-4-5", cache_read=int(rw.SMALL_CONTEXT_LIMIT * 0.91))])
        report = rw.context_report(transcript, None)
        self.assertEqual((report["percent"], report["level"]), (91.0, "wrap_up"))


class ResumeCron(Sandboxed):

    @classmethod
    def setUpClass(cls):
        cls.previous_tz = os.environ.get("TZ")
        os.environ["TZ"] = "UTC"
        time.tzset()

    @classmethod
    def tearDownClass(cls):
        if cls.previous_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = cls.previous_tz
        time.tzset()

    def test_pads_past_the_reset(self):
        self.assertEqual(rw.resume_cron("2026-09-15T02:20:00+00:00"), "22 2 15 9 *")

    def test_handles_a_z_suffix(self):
        self.assertEqual(rw.resume_cron("2026-09-15T02:20:00Z"), "22 2 15 9 *")

    def test_rolls_over_midnight(self):
        self.assertEqual(rw.resume_cron("2026-09-15T23:59:00+00:00"), "1 0 16 9 *")

    def test_rolls_over_the_year(self):
        self.assertEqual(rw.resume_cron("2026-12-31T23:59:00+00:00"), "1 0 1 1 *")

    def test_converts_to_local_time(self):
        self.assertEqual(rw.resume_cron("2026-09-15T02:20:00+02:00"), "22 0 15 9 *")

    def test_no_timestamp(self):
        self.assertIsNone(rw.resume_cron(None))


class Actions(Sandboxed):

    def setUp(self):
        super().setUp()
        os.environ["RUNWAY_STOP_WORK"] = "1"

    @staticmethod
    def bucket(level="stop", percent=99, minutes=240, cron="22 2 15 9 *", active=True,
               scope=None, applies=True):
        return {"kind": "session", "group": "session",
                "label": f"session:{scope}" if scope else "session", "percent": percent,
                "resets_at": "2026-09-15T02:20:00+00:00", "resets_local": "02:20",
                "minutes_to_reset": minutes, "resume_cron": cron, "is_active": active,
                "scope_model": scope, "applies": applies, "level": level}

    def test_a_quota_stop_hands_over_a_cron_expression(self):
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket()]})
        self.assertIn('cron "22 2 15 9 *"', actions[0])
        self.assertIn("CronCreate", actions[0])

    def test_a_near_reset_says_wait_rather_than_schedule(self):
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket(minutes=3)]})
        self.assertIn("refills in 3m", actions[0])
        self.assertNotIn("CronCreate", actions[0])

    def test_a_missing_cron_falls_back_to_the_clock_time(self):
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket(cron=None)]})
        self.assertNotIn("CronCreate", actions[0])
        self.assertIn("02:20", actions[0])

    def test_wrap_up_schedules_only_if_it_pauses(self):
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket(level="wrap_up", percent=96)]})
        self.assertIn("stop starting new work", actions[0])
        self.assertIn("If you pause before then", actions[0])
        self.assertIn('cron "22 2 15 9 *"', actions[0])

    def test_the_restart_resumes_this_session_without_a_note(self):
        for level in ("wrap_up", "stop"):
            actions, _ = rw.build_actions(None, {"buckets": [self.bucket(level=level)]})
            self.assertIn(rw.RESTART_PROMPT, actions[0])
            self.assertIn("in this session", actions[0])
            self.assertNotIn("note", actions[0])

    def test_an_unscoped_bucket_flagged_inactive_still_acts(self):
        actions, notes = rw.build_actions(None, {"buckets": [self.bucket(active=False)]})
        self.assertEqual(notes, [])
        self.assertIn("CronCreate", actions[0])

    def test_ok_buckets_are_ignored(self):
        self.assertEqual(rw.build_actions(None, {"buckets": [self.bucket(level="ok",
                                                                        percent=10)]}), ([], []))

    def test_a_full_context_asks_for_a_fresh_session(self):
        actions, _ = rw.build_actions({"level": "stop", "percent": 96, "limit": 1_000_000}, None)
        self.assertIn("fresh session", actions[0])

    def test_a_bucket_for_another_model_never_becomes_an_action(self):
        actions, notes = rw.build_actions(
            {"level": "ok", "percent": 11, "limit": 1_000_000, "model": "claude-opus-5"},
            {"buckets": [self.bucket(scope="Fable", applies=False)]})
        self.assertEqual(actions, [])
        self.assertIn("DOES NOT APPLY", notes[0])
        self.assertIn("Fable", notes[0])
        self.assertIn("claude-opus-5", notes[0])

    def test_a_note_for_another_model_forbids_pausing(self):
        _, notes = rw.build_actions(
            {"level": "ok", "percent": 11, "limit": 1_000_000, "model": "claude-opus-5"},
            {"buckets": [self.bucket(scope="Fable", applies=False)]})
        self.assertNotIn("CronCreate", notes[0])
        self.assertIn("keep working", notes[0])

    def test_a_bucket_for_the_running_model_still_acts(self):
        actions, notes = rw.build_actions(
            {"level": "ok", "percent": 11, "limit": 1_000_000, "model": "claude-fable-5-1"},
            {"buckets": [self.bucket(scope="Fable", applies=True)]})
        self.assertEqual(notes, [])
        self.assertIn("CronCreate", actions[0])


def wake_in(**delta):
    """A local wake string offset from now, since a recorded wake only counts until it fires."""
    return (datetime.now() + timedelta(**delta)).strftime(rw.WAKE_FORMAT)


class KeepWorking(Sandboxed):
    """Default mode: quota thresholds never ask for a pause, they point at `until` for a 429."""

    bucket = staticmethod(Actions.bucket)
    SOON = wake_in(hours=1)
    WEEK = wake_in(days=5)
    FIRED = wake_in(hours=-1)

    def weekly(self, wake=None):
        b = self.bucket(level="wrap_up", percent=96)
        b.update(group="weekly", label="weekly", wake_at=wake or self.WEEK)
        return b

    def test_no_pause_instructions_at_any_quota_level(self):
        for level in ("notice", "wrap_up", "stop"):
            actions, _ = rw.build_actions(None, {"buckets": [self.bucket(level=level)]})
            self.assertIn("keep working normally", actions[0])
            self.assertNotIn("CronCreate", actions[0])
            self.assertNotIn("stop starting new work", actions[0])

    def test_a_near_reset_does_not_pause_either(self):
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket(minutes=3)]})
        self.assertNotIn("pause here", actions[0])
        self.assertIn("keep working normally", actions[0])

    def test_notice_only_informs(self):
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket(level="notice")]})
        self.assertNotIn("delayed-work:until", actions[0])

    def test_wrap_up_arms_until_once_with_the_wake_time(self):
        b = self.bucket(level="wrap_up", percent=96)
        b["wake_at"] = self.SOON
        actions, _ = rw.build_actions(None, {"buckets": [b]})
        self.assertIn("delayed-work:until", actions[0])
        self.assertIn(self.SOON, actions[0])
        self.assertIn(f'`python3 "{rw.SCRIPT}" --armed "{self.SOON}" --bucket session`',
                      actions[0])
        self.assertIn("Set RUNWAY_STOP_WORK=1 to pause until the reset instead.", actions[0])
        self.assertTrue(rw.SCRIPT.is_absolute())
        self.assertIn("429", actions[0])

    def test_a_weekly_bucket_offers_arm_or_acknowledge(self):
        actions, _ = rw.build_actions(None, {"buckets": [self.weekly()]})
        self.assertIn("your call", actions[0])
        self.assertIn(f'--armed "{self.WEEK}" --bucket weekly', actions[0])
        self.assertIn(f'--ack "{self.WEEK}" --bucket weekly', actions[0])

    def test_an_acknowledged_weekly_bucket_goes_quiet(self):
        rw.record_armed("sess-1", self.WEEK, "weekly", ack=True)
        armed = rw.armed_wakes("sess-1")
        quota = {"buckets": [self.weekly()]}
        actions, _ = rw.build_actions(None, quota, armed)
        self.assertIn("acknowledged", actions[0])
        self.assertNotIn("--ack", actions[0])
        self.assertTrue(rw.all_armed(None, quota, armed))

    def test_an_acknowledgement_lapses_when_its_reset_passes(self):
        rw.record_armed("sess-1", self.FIRED, "weekly", ack=True)
        armed = rw.armed_wakes("sess-1")
        quota = {"buckets": [self.weekly()]}
        actions, _ = rw.build_actions(None, quota, armed)
        self.assertIn("--ack", actions[0])
        self.assertFalse(rw.all_armed(None, quota, armed))

    def check(self, bucket):
        """One prompt-hook check through collect(), with the quota stubbed: (report, brief)."""
        quota = {"plan": None, "tier": None, "buckets": [bucket], "session": None,
                 "level": bucket["level"]}
        with mock.patch.object(rw, "read_credentials",
                               return_value={"claudeAiOauth": {"accessToken": "t"}}), \
             mock.patch.object(rw, "quota_report", return_value=quota):
            report = rw.collect("sess-1", "/tmp/nowhere", None, new_session=True)
        rw.write_state(report, "sess-1")
        return report, self.brief(report)

    def test_a_weekly_ack_quiets_the_next_prompt_and_a_new_window_nags_once(self):
        _, first = self.check(self.weekly())
        self.assertIn("--ack", first)
        self.assertIn("invoke the `runway` skill", first)
        rw.record_armed("sess-1", rw.last_wake("weekly"), "weekly", ack=True)
        report, second = self.check(self.weekly())
        self.assertTrue(report["armed_quiet"])
        self.assertNotIn("invoke the `runway` skill", second)
        self.assertTrue(rw.throttled(900, "sess-1"))
        rw.record_armed("sess-1", self.FIRED, "weekly", ack=True)
        _, renag = self.check(self.weekly(wake_in(days=7)))
        self.assertIn("invoke the `runway` skill", renag)
        rw.record_armed("sess-1", rw.last_wake("weekly"), "weekly", ack=True)
        _, after = self.check(self.weekly(wake_in(days=7)))
        self.assertNotIn("invoke the `runway` skill", after)

    def test_an_already_armed_wake_is_not_requested_again(self):
        b = self.bucket()
        b["wake_at"] = self.SOON
        actions, _ = rw.build_actions(None, {"buckets": [b]}, armed={"session": self.SOON})
        self.assertNotIn("delayed-work:until", actions[0])
        self.assertIn("already armed", actions[0])

    def test_a_one_minute_reset_drift_stays_armed(self):
        b = self.bucket()
        b["wake_at"] = wake_in(hours=1, minutes=1)
        self.assertTrue(rw.is_armed(b, {"session": self.SOON}))
        b["wake_at"] = wake_in(minutes=59)
        self.assertTrue(rw.is_armed(b, {"session": self.SOON}))

    def test_a_new_reset_window_asks_again(self):
        b = self.bucket()
        b["wake_at"] = self.SOON
        actions, _ = rw.build_actions(None, {"buckets": [b]}, armed={"session": self.FIRED})
        self.assertIn("delayed-work:until", actions[0])

    def test_an_unparseable_record_reads_as_unarmed(self):
        b = self.bucket()
        b["wake_at"] = self.SOON
        self.assertFalse(rw.is_armed(b, {"session": "soon"}))
        self.assertFalse(rw.is_armed(b, {"session": {"ack": None}}))

    def test_a_missing_wake_time_points_at_the_json_report(self):
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket()]})
        self.assertIn("runway.py --json", actions[0])

    def test_armed_roundtrips_through_state_and_survives_a_check(self):
        rw.record_armed("sess-1", self.SOON, "session")
        self.assertEqual(rw.armed_wakes("sess-1"), {"session": self.SOON})
        self.assertEqual(rw.armed_wakes("sess-2"), {})
        rw.write_state({"level": "ok", "context": None, "quota": None})
        self.assertEqual(rw.armed_wakes("sess-1"), {"session": self.SOON})

    def test_two_tight_buckets_keep_one_wake_each(self):
        rw.record_armed("sess-1", self.SOON, "session")
        rw.record_armed("sess-1", self.WEEK, "weekly")
        session = self.bucket()
        session["wake_at"] = self.SOON
        weekly = self.weekly()
        actions, _ = rw.build_actions(None, {"buckets": [session, weekly]},
                                      armed=rw.armed_wakes("sess-1"))
        self.assertEqual(len(actions), 2)
        for action in actions:
            self.assertIn("already armed", action)

    def test_an_unlabelled_arm_matches_only_its_own_wake_time(self):
        rw.record_armed("sess-1", self.SOON)
        b = self.bucket()
        b["wake_at"] = wake_in(hours=1, minutes=1)
        self.assertTrue(rw.is_armed(b, rw.armed_wakes("sess-1")))
        b["wake_at"] = self.WEEK
        self.assertFalse(rw.is_armed(b, rw.armed_wakes("sess-1")))

    def test_a_legacy_string_entry_reads_as_unarmed(self):
        rw.write_raw_state({"armed": {"sess-1": self.SOON}})
        self.assertEqual(rw.armed_wakes("sess-1"), {})
        rw.record_armed("sess-1", self.SOON, "session")
        self.assertEqual(rw.armed_wakes("sess-1"), {"session": self.SOON})

    def armed_report(self, armed):
        b = self.bucket()
        b["wake_at"] = self.SOON
        quota = {"buckets": [b]}
        actions, notes = rw.build_actions(None, quota, armed)
        return {"level": "stop", "quota": quota, "context": None, "actions": actions,
                "notes": notes, "errors": [], "armed_quiet": rw.all_armed(None, quota, armed)}

    def brief(self, report):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            rw.render_brief(report)
        return out.getvalue()

    def test_an_armed_bucket_silences_the_invoke_nudge_and_throttles(self):
        report = self.armed_report({"session": self.SOON})
        self.assertTrue(report["armed_quiet"])
        self.assertNotIn("invoke the `runway` skill", self.brief(report))
        rw.write_state(report, "sess-1")
        self.assertTrue(rw.throttled(900, "sess-1"))

    def test_an_unarmed_bucket_keeps_nudging_every_prompt(self):
        report = self.armed_report({})
        self.assertFalse(report["armed_quiet"])
        self.assertIn("invoke the `runway` skill", self.brief(report))
        rw.write_state(report, "sess-1")
        self.assertFalse(rw.throttled(900, "sess-1"))

    def test_one_session_armed_does_not_quiet_another_at_the_same_quota(self):
        rw.record_armed("sess-a", self.SOON, "session")
        rw.write_state(self.armed_report(rw.armed_wakes("sess-a")), "sess-a")
        self.assertTrue(rw.throttled(900, "sess-a"))
        self.assertFalse(rw.throttled(900, "sess-b"))
        output = self.brief(self.armed_report(rw.armed_wakes("sess-b")))
        self.assertIn("runway ACTION:", output)
        self.assertIn("invoke the `runway` skill", output)

    def test_one_sessions_clean_check_does_not_throttle_another(self):
        rw.write_state({"level": "ok", "context": None, "quota": None}, "sess-a")
        self.assertTrue(rw.throttled(900, "sess-a"))
        self.assertFalse(rw.throttled(900, "sess-b"))

    def test_no_session_id_is_never_throttled(self):
        rw.write_state({"level": "ok", "context": None, "quota": None}, "sess-a")
        self.assertFalse(rw.throttled(900, None))

    def test_stale_throttle_markers_are_pruned(self):
        old = int(rw.time.time()) - rw.THROTTLE_MARKER_TTL - 1
        rw.write_raw_state({"throttle": {"gone": {"at": old, "quiet": True}}})
        rw.write_state({"level": "ok", "context": None, "quota": None}, "sess-a")
        self.assertEqual(set(json.loads(rw.STATE_FILE.read_text())["throttle"]), {"sess-a"})

    def test_stop_work_mode_is_never_quiet(self):
        os.environ["RUNWAY_STOP_WORK"] = "1"
        self.assertFalse(self.armed_report({"session": self.SOON})["armed_quiet"])

    def test_a_tight_context_is_never_quiet(self):
        b = self.bucket()
        b["wake_at"] = self.SOON
        self.assertFalse(rw.all_armed({"level": "wrap_up"}, {"buckets": [b]},
                                      {"session": self.SOON}))

    def test_stop_work_notice_only_mentions_the_reset(self):
        os.environ["RUNWAY_STOP_WORK"] = "1"
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket(level="notice",
                                                                     percent=91)]})
        self.assertEqual(actions, ["session quota at 91%, refills 02:20 (in 4h 0m): "
                                   "keep working normally."])

    def run_main(self, *args, payload=None):
        """Run main() in-process as a hook would, with the quota stubbed at 96%: stdout."""
        b = self.bucket(level="wrap_up", percent=96)
        b["wake_at"] = self.SOON
        quota = {"plan": None, "tier": None, "buckets": [b], "session": None, "level": "wrap_up"}
        out = io.StringIO()
        with mock.patch.object(rw, "read_credentials",
                               return_value={"claudeAiOauth": {"accessToken": "t"}}), \
             mock.patch.object(rw, "quota_report", return_value=quota), \
             mock.patch.object(rw, "hook_payload", return_value=payload or {}), \
             mock.patch("sys.argv", ["runway.py", *args]), mock.patch("sys.stdout", out):
            self.assertEqual(rw.main(), 0)
        return out.getvalue()

    PROMPT = ("--brief", "--throttle", "900", "--no-self-install")

    def test_the_prompt_after_an_arm_or_ack_is_silent(self):
        for flag in (["--armed", self.SOON], ["--ack"]):
            with self.subTest(flag=flag[0]):
                rw.write_raw_state({})
                hook = {"hook_event_name": "UserPromptSubmit", "session_id": "sess-1"}
                self.assertIn("runway ACTION:", self.run_main(*self.PROMPT, payload=hook))
                self.assertEqual(self.run_main(*flag, "--bucket", "session",
                                               "--session", "sess-1"), "")
                self.assertEqual(self.run_main(*self.PROMPT, payload=hook), "")

    def test_stop_work_mode_keeps_reporting_after_an_arm(self):
        os.environ["RUNWAY_STOP_WORK"] = "1"
        hook = {"hook_event_name": "UserPromptSubmit", "session_id": "sess-1"}
        self.run_main(*self.PROMPT, payload=hook)
        self.run_main("--armed", self.SOON, "--bucket", "session", "--session", "sess-1")
        self.assertIn("runway ACTION:", self.run_main(*self.PROMPT, payload=hook))

    def test_stop_work_env_restores_the_pause(self):
        os.environ["RUNWAY_STOP_WORK"] = "1"
        actions, _ = rw.build_actions(None, {"buckets": [self.bucket()]})
        self.assertIn("CronCreate", actions[0])

    def test_falsy_stop_work_values_stay_in_default_mode(self):
        for value in ("0", "false", "no", ""):
            os.environ["RUNWAY_STOP_WORK"] = value
            actions, _ = rw.build_actions(None, {"buckets": [self.bucket()]})
            self.assertIn("keep working normally", actions[0])

    def test_a_full_context_hands_off_to_a_fresh_session(self):
        actions, _ = rw.build_actions({"level": "stop", "percent": 96, "limit": 1_000_000}, None)
        self.assertIn("fresh session", actions[0])
        self.assertIn("`handoff` skill", actions[0])

    def test_wake_clock_pads_two_minutes_in_local_time(self):
        self.assertRegex(rw.wake_clock("2026-09-15T02:20:00+00:00"), r"^2026-09-1\d \d\d:22$")
        self.assertIsNone(rw.wake_clock(None))


class ScopedBuckets(Sandboxed):

    @staticmethod
    def bucket(scope):
        return {"scope_model": scope}

    def test_an_unscoped_bucket_always_applies(self):
        self.assertTrue(rw.bucket_applies({"scope_model": None}, "claude-opus-5"))

    def test_a_scope_matching_the_model_applies(self):
        self.assertTrue(rw.bucket_applies(self.bucket("Fable"), "claude-fable-5-1"))

    def test_a_scope_for_another_model_does_not_apply(self):
        self.assertFalse(rw.bucket_applies(self.bucket("Fable"), "claude-opus-5"))
        self.assertFalse(rw.bucket_applies(self.bucket("Opus"), "claude-sonnet-5"))

    def test_an_unknown_model_leaves_the_bucket_standing(self):
        self.assertTrue(rw.bucket_applies(self.bucket("Fable"), None))

    def test_the_api_active_flag_does_not_decide_scope(self):
        """The usage endpoint calls a Fable weekly bucket active while Opus runs."""
        bucket = {"scope_model": "Fable", "is_active": True}
        self.assertFalse(rw.bucket_applies(bucket, "claude-opus-5"))

    def test_a_version_scope_matches_its_own_model_and_1m_variant(self):
        for model in ("claude-opus-5", "claude-opus-5[1m]"):
            with self.subTest(model=model):
                self.assertTrue(rw.bucket_applies(self.bucket("Opus 5"), model))


class ModelScope(Sandboxed):
    """A model-scoped limit counts only for sessions running that model."""

    @staticmethod
    def bucket(scope="Fable", active=True, percent=93):
        label = f"weekly_scoped:{scope}" if scope else "session"
        return {"kind": "weekly_scoped" if scope else "session",
                "group": "weekly" if scope else "session", "label": label,
                "percent": percent, "resets_local": "21:00", "minutes_to_reset": 600,
                "resume_cron": "2 21 5 10 *", "wake_at": "2026-10-05 21:02",
                "is_active": active, "scope_model": scope,
                "level": rw.level_for("quota", percent)}

    def quota(self, *buckets):
        return {"buckets": list(buckets), "level": "ok"}

    def test_the_active_flag_does_not_put_an_opus_session_on_a_fable_limit(self):
        quota = self.quota(self.bucket(active=True))
        rw.apply_model(quota, "claude-opus-5")
        self.assertFalse(quota["buckets"][0]["applies"])

    def test_a_fable_limit_applies_to_a_fable_session(self):
        quota = self.quota(self.bucket(active=False))
        rw.apply_model(quota, "claude-fable-5-1")
        self.assertTrue(quota["buckets"][0]["applies"])

    def test_an_unscoped_limit_applies_even_when_flagged_inactive(self):
        quota = self.quota(self.bucket(scope=None, active=False))
        rw.apply_model(quota, "claude-opus-5")
        self.assertTrue(quota["buckets"][0]["applies"])

    def test_an_unknown_model_falls_back_to_the_active_flag(self):
        quota = self.quota(self.bucket(active=False))
        rw.apply_model(quota, None)
        self.assertFalse(quota["buckets"][0]["applies"])

    def test_multi_word_scopes_match_the_model_id(self):
        quota = self.quota(self.bucket(scope="Sonnet 4.5"))
        rw.apply_model(quota, "claude-sonnet-4-5-20250929")
        self.assertTrue(quota["buckets"][0]["applies"])

    def test_a_version_scope_matches_its_own_point_release(self):
        quota = self.quota(self.bucket(scope="Opus 5.5"))
        rw.apply_model(quota, "claude-opus-5-5[1m]")
        self.assertTrue(quota["buckets"][0]["applies"])

    def test_a_version_scope_skips_a_newer_point_release(self):
        quota = self.quota(self.bucket(scope="Opus 5"))
        rw.apply_model(quota, "claude-opus-5-5")
        self.assertFalse(quota["buckets"][0]["applies"])

    def test_a_version_scope_still_matches_a_dated_id(self):
        quota = self.quota(self.bucket(scope="Opus 5"))
        rw.apply_model(quota, "claude-opus-5-20260101")
        self.assertTrue(quota["buckets"][0]["applies"])

    def test_a_family_scope_covers_every_version(self):
        quota = self.quota(self.bucket(scope="Opus"))
        rw.apply_model(quota, "claude-opus-5-5")
        self.assertTrue(quota["buckets"][0]["applies"])

    def test_another_models_limit_does_not_raise_the_level(self):
        quota = self.quota(self.bucket(percent=99), self.bucket(scope=None, percent=8))
        rw.apply_model(quota, "claude-opus-5")
        self.assertEqual(quota["level"], "ok")

    def test_the_running_models_limit_still_raises_the_level(self):
        quota = self.quota(self.bucket(percent=99))
        rw.apply_model(quota, "claude-fable-5-1")
        self.assertEqual(quota["level"], "stop")

    def test_another_models_tight_limit_is_flagged_as_ignorable(self):
        quota = self.quota(self.bucket(percent=93))
        rw.apply_model(quota, "claude-opus-5")
        actions, notes = rw.build_actions(None, quota, model="claude-opus-5")
        self.assertEqual(actions, [])
        self.assertEqual(len(notes), 1)
        self.assertIn("DOES NOT APPLY", notes[0])
        self.assertIn("claude-opus-5", notes[0])
        self.assertNotIn("stop starting new work", notes[0])

    def test_nothing_is_ignorable_when_the_model_is_unknown(self):
        quota = self.quota(self.bucket(active=False, percent=93))
        rw.apply_model(quota, None)
        self.assertEqual(rw.build_actions(None, quota), ([], []))

    def test_the_brief_output_never_turns_another_models_limit_into_an_action(self):
        quota = self.quota(self.bucket(percent=93), self.bucket(scope=None, percent=8))
        rw.apply_model(quota, "claude-opus-5")
        actions, notes = rw.build_actions(None, quota, model="claude-opus-5")
        report = {"quota": quota, "context": None, "level": quota["level"],
                  "actions": actions, "notes": notes, "errors": []}
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            rw.render_brief(report)
        printed = out.getvalue()
        self.assertNotIn("runway ACTION", printed)
        self.assertNotIn("invoke the `runway` skill", printed)
        self.assertIn("runway IGNORE: weekly_scoped:Fable", printed)

    def collect_with(self, quota, hook_model=None):
        """Run collect() on a stubbed quota with no transcript, so only fallbacks name the model."""
        with mock.patch.object(rw, "read_credentials",
                               return_value={"claudeAiOauth": {"accessToken": "t"}}), \
             mock.patch.object(rw, "quota_report", return_value=quota):
            return rw.collect("s1", "/tmp/nowhere", None, hook_model, new_session=True)

    def test_the_hook_model_scopes_buckets_without_a_transcript(self):
        report = self.collect_with(self.quota(self.bucket(scope="Opus 5", percent=99)),
                                   hook_model="claude-fable-5-1")
        self.assertEqual(report["quota"]["level"], "ok")
        self.assertIn("claude-fable-5-1", report["notes"][0])

    def test_the_cached_model_scopes_buckets_when_the_hook_carries_none(self):
        rw.remember_model("s1", "claude-opus-5[1m]")
        report = self.collect_with(self.quota(self.bucket(scope="Opus 5", percent=99)))
        self.assertEqual(report["quota"]["level"], "stop")
        self.assertEqual(report["notes"], [])


class PluginHooks(Sandboxed):

    def layout(self, hooks_text):
        script = self.home / "plugin" / "skills" / "runway" / "scripts" / "runway.py"
        script.parent.mkdir(parents=True)
        if hooks_text is not None:
            (self.home / "plugin" / "hooks").mkdir()
            (self.home / "plugin" / "hooks" / "hooks.json").write_text(hooks_text)
        return script

    def test_a_plugin_hooks_file_naming_runway_counts(self):
        script = self.layout('{"command": "python3 runway.py --brief"}')
        self.assertTrue(rw.ships_plugin_hooks(script))
        self.assertTrue(ih.ships_plugin_hooks(script))

    def test_a_standalone_copy_has_none(self):
        self.assertFalse(rw.ships_plugin_hooks(self.layout(None)))

    def test_someone_elses_hooks_file_does_not_count(self):
        self.assertFalse(rw.ships_plugin_hooks(self.layout('{"command": "other"}')))

    def test_a_shallow_path_does_not_raise(self):
        self.assertFalse(rw.ships_plugin_hooks(Path("/runway.py")))

    def test_the_shipped_hooks_disable_self_install_and_match_the_installer(self):
        shipped = json.loads((SCRIPTS.parents[2] / "hooks" / "hooks.json").read_text())
        self.assertEqual(set(shipped["hooks"]), set(ih.EVENTS))
        for groups in shipped["hooks"].values():
            for entry in groups[0]["hooks"]:
                self.assertIn("--no-self-install", entry["command"])
                self.assertIn('"${CLAUDE_PLUGIN_ROOT}/skills/runway/scripts/runway.py"',
                              entry["command"])
        self.assertTrue(rw.ships_plugin_hooks())


class Standalone(Sandboxed):
    """These scripts sit inside the plugin; these cases check them as a standalone copy."""

    def setUp(self):
        super().setUp()
        patch = mock.patch.object(rw, "ships_plugin_hooks", return_value=False)
        patch.start()
        self.addCleanup(patch.stop)

    def complete(self):
        settings = {}
        ih.add_runway(settings, with_prompt_hook=True)
        self.write_settings(settings)


class HooksInstalled(Standalone):

    def test_no_settings_file(self):
        self.assertTrue(rw.setup_problems())

    def test_unreadable_settings(self):
        (self.home / "settings.json").write_text("{ truncated")
        self.assertTrue(rw.setup_problems())

    def test_someone_elses_hooks_do_not_count(self):
        self.write_settings({"hooks": {"SessionStart": [
            {"hooks": [{"type": "command", "command": "other-tool --check"}]}]}})
        self.assertTrue(rw.setup_problems())

    def test_a_partial_install_does_not_count(self):
        self.write_settings({"hooks": {"SessionStart": [ih.hook_group()]}})
        self.assertTrue(rw.setup_problems())

    def test_a_complete_install_counts(self):
        self.complete()
        self.assertEqual(rw.setup_problems(), [])

    def test_a_malformed_hooks_block_does_not_raise(self):
        self.write_settings({"hooks": {"SessionStart": "not-a-list"}})
        self.assertTrue(rw.setup_problems())


class SetupCheck(Standalone):
    """The session-start hook tells the agent when a standalone install needs repair."""

    def test_a_complete_install_needs_nothing(self):
        self.complete()
        self.assertEqual(rw.setup_problems(), [])

    def test_a_partial_install_is_reported(self):
        self.write_settings({"hooks": {"SessionStart": [ih.hook_group()]}})
        self.assertEqual(rw.setup_problems(), ["PostModelSwitch: missing"])

    def test_no_settings_file_reports_every_required_hook(self):
        self.assertEqual(rw.setup_problems(),
                         ["SessionStart: missing", "PostModelSwitch: missing"])

    def test_unreadable_settings_are_reported_not_raised(self):
        (self.home / "settings.json").write_text("{ truncated")
        self.assertEqual(rw.setup_problems(), ["settings.json is not valid JSON"])

    def test_the_setup_line_gives_the_fix_and_the_user_fallback(self):
        line = rw.setup_line(["PostModelSwitch: missing"])
        self.assertTrue(line.startswith("runway SETUP:"))
        self.assertIn("PostModelSwitch: missing", line)
        self.assertIn(f'python3 "{rw.INSTALLER}"', line)
        self.assertIn(f'! python3 "{rw.INSTALLER}"', line)

    def test_the_brief_output_prints_setup_and_points_at_the_skill(self):
        report = {"quota": None, "context": None, "level": "ok", "actions": [], "notes": [],
                  "setup": ["SessionStart: out of date"], "errors": []}
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            rw.render_brief(report)
        printed = out.getvalue()
        self.assertIn("runway SETUP:", printed)
        self.assertIn("invoke the `runway` skill", printed)

    def test_a_failed_self_install_asks_the_user(self):
        notice = rw.self_install_notice(False, "PermissionError: settings.json")
        self.assertIn("install failed", notice)
        self.assertIn(f'! python3 "{rw.INSTALLER}"', notice)


class PluginSetup(Sandboxed):
    """Inside the plugin, hooks.json is the install: an empty settings file needs no repair."""

    def test_no_settings_hooks_is_not_a_problem(self):
        self.assertTrue(rw.ships_plugin_hooks())
        self.assertEqual(rw.setup_problems(), [])
        self.assertEqual(ih.problems({}), [])


class Thresholds(Sandboxed):

    def test_boundaries_are_inclusive(self):
        self.assertEqual(rw.level_for("context", 80), "notice")
        self.assertEqual(rw.level_for("context", 79.9), "ok")
        self.assertEqual(rw.level_for("context", 95), "stop")

    def test_env_override(self):
        os.environ["RUNWAY_CONTEXT_WRAP_UP"] = "50"
        self.assertEqual(rw.level_for("context", 55), "wrap_up")

    def test_junk_override_is_ignored(self):
        os.environ["RUNWAY_CONTEXT_STOP"] = "high"
        self.assertEqual(rw.level_for("context", 96), "stop")

    def test_worst_of_a_mixed_set(self):
        self.assertEqual(rw.worst(["ok", "stop", "notice"]), "stop")

    def test_worst_of_nothing(self):
        self.assertEqual(rw.worst([]), "ok")


class Collect(Sandboxed):

    def test_no_credentials_reports_an_error_and_never_calls_out(self):
        self.write_transcript("s1", [self.assistant_turn("claude-opus-5[1m]", cache_read=10)])
        with mock.patch.object(rw, "read_credentials", return_value=None), \
             mock.patch.object(rw, "fetch_quota", side_effect=AssertionError("called out")):
            report = rw.collect("s1", "/tmp/proj", None)
        self.assertIsNone(report["quota"])
        self.assertEqual(report["context"]["tokens"], 10)
        self.assertTrue(any("OAuth" in error for error in report["errors"]))

    def test_a_missing_transcript_is_reported_not_raised(self):
        with mock.patch.object(rw, "read_credentials", return_value=None):
            report = rw.collect("nobody", "/tmp/nowhere", None)
        self.assertIsNone(report["context"])
        self.assertTrue(any("no transcript" in error for error in report["errors"]))

    def test_a_new_session_has_no_transcript_warning(self):
        with mock.patch.object(rw, "read_credentials", return_value=None):
            report = rw.collect("new", "/tmp/nowhere", None, new_session=True)
        self.assertFalse(any("transcript" in error for error in report["errors"]))

    def test_a_new_session_with_an_empty_transcript_has_no_warning(self):
        self.write_transcript("new", [json.dumps({"type": "user"})])
        with mock.patch.object(rw, "read_credentials", return_value=None):
            report = rw.collect("new", "/tmp/proj", None, new_session=True)
        self.assertFalse(any("token counts" in error for error in report["errors"]))


class FindTranscript(Sandboxed):

    def test_a_known_session_never_borrows_another_sessions_transcript(self):
        self.write_transcript("old", [self.assistant_turn("claude-opus-5-5", cache_read=280_000)])
        self.assertIsNone(rw.find_transcript("new", "/tmp/proj"))

    def test_a_known_session_finds_its_own_transcript(self):
        path = self.write_transcript("s1", [self.assistant_turn("claude-opus-5-5")])
        self.assertEqual(rw.find_transcript("s1", "/tmp/proj"), path)

    def test_a_known_session_is_found_under_another_project(self):
        path = self.write_transcript("s1", [self.assistant_turn("claude-opus-5-5")], cwd="/tmp/b")
        self.assertEqual(rw.find_transcript("s1", "/tmp/a"), path)

    def test_without_a_session_id_the_newest_transcript_is_used(self):
        old = self.write_transcript("old", [self.assistant_turn("claude-opus-5-5")])
        new = self.write_transcript("new", [self.assistant_turn("claude-opus-5-5")])
        os.utime(old, (1, 1))
        self.assertEqual(rw.find_transcript(None, "/tmp/proj"), new)


class Installer(unittest.TestCase):
    """install-hooks.py merge behaviour, on dicts only: nothing is written to disk."""

    FOREIGN = {"hooks": [{"type": "command", "command": "other-tool run"}]}

    def fresh(self):
        settings = {"hooks": {"SessionStart": [dict(self.FOREIGN)]}}
        ih.add_runway(settings, with_prompt_hook=True)
        return settings

    def test_installs_three_events(self):
        settings = self.fresh()
        self.assertEqual({event for event, _ in ih.installed_commands(settings)},
                         {"SessionStart", "UserPromptSubmit", "PostModelSwitch"})

    def test_the_model_recorder_is_silent_and_unthrottled(self):
        settings = self.fresh()
        command = dict(ih.installed_commands(settings))["PostModelSwitch"]
        self.assertIn("--record-model", command)
        self.assertNotIn("--brief", command)
        self.assertNotIn("--throttle", command)

    def test_foreign_hooks_survive_a_reinstall(self):
        settings = self.fresh()
        ih.strip_runway(settings)
        ih.add_runway(settings, with_prompt_hook=True)
        self.assertIn(self.FOREIGN, settings["hooks"]["SessionStart"])

    def test_reinstalling_does_not_duplicate(self):
        settings = self.fresh()
        for _ in range(3):
            ih.strip_runway(settings)
            ih.add_runway(settings, with_prompt_hook=True)
        self.assertEqual(len(ih.installed_commands(settings)), 3)

    def test_uninstall_removes_every_entry_and_prunes_empty_events(self):
        settings = self.fresh()
        stripped = ih.strip_runway(settings)
        self.assertEqual(stripped, 3)
        self.assertEqual(ih.installed_commands(settings), [])
        self.assertNotIn("PostModelSwitch", settings["hooks"])
        self.assertIn(self.FOREIGN, settings["hooks"]["SessionStart"])

    def test_uninstall_drops_the_hooks_key_when_nothing_is_left(self):
        settings = {}
        ih.add_runway(settings, with_prompt_hook=True)
        ih.strip_runway(settings)
        self.assertNotIn("hooks", settings)

    def test_no_prompt_hook_still_records_the_model(self):
        settings = {}
        ih.add_runway(settings, with_prompt_hook=False)
        self.assertEqual({event for event, _ in ih.installed_commands(settings)},
                         {"SessionStart", "PostModelSwitch"})

    def test_strip_tolerates_a_malformed_block(self):
        settings = {"hooks": {"SessionStart": "not-a-list"}}
        self.assertEqual(ih.strip_runway(settings), 0)

    def test_strip_on_settings_without_hooks(self):
        self.assertEqual(ih.strip_runway({"model": "claude-opus-5"}), 0)

    def test_paths_with_spaces_stay_quoted(self):
        self.assertIn(f'"{ih.SCRIPT}"', ih.hook_command())

    def test_hooks_run_through_python_so_the_execute_bit_does_not_matter(self):
        self.assertTrue(ih.hook_command().startswith("python3 "))

    def test_a_complete_install_has_no_problems(self):
        self.assertEqual(ih.problems(self.fresh(), plugin=False), [])

    def test_the_prompt_hook_is_optional(self):
        settings = {}
        ih.add_runway(settings, with_prompt_hook=False)
        self.assertEqual(ih.problems(settings, plugin=False), [])

    def test_a_missing_model_recorder_is_a_problem(self):
        settings = {"hooks": {"SessionStart": [ih.hook_group()]}}
        self.assertEqual(ih.problems(settings, plugin=False), ["PostModelSwitch: missing"])

    def test_an_old_command_is_a_problem(self):
        settings = self.fresh()
        settings["hooks"]["PostModelSwitch"] = [{"hooks": [
            {"type": "command", "command": f'"{ih.SCRIPT}" --record-model'}]}]
        self.assertEqual(ih.problems(settings, plugin=False), ["PostModelSwitch: out of date"])

    def test_hook_commands_carry_the_hooks_version(self):
        self.assertIn(f"--hooks-version {ih.HOOKS_VERSION}", ih.hook_command())

    def test_an_older_hooks_version_is_a_problem(self):
        settings = self.fresh()
        old = ih.hook_command().replace(f"--hooks-version {ih.HOOKS_VERSION}",
                                        f"--hooks-version {ih.HOOKS_VERSION - 1}")
        settings["hooks"]["SessionStart"] = [{"hooks": [{"type": "command", "command": old}]}]
        self.assertEqual(ih.problems(settings, plugin=False), ["SessionStart: out of date"])

    def test_a_hand_wired_current_command_is_accepted(self):
        settings = self.fresh()
        settings["hooks"]["SessionStart"] = [{"hooks": [{"type": "command", "command":
            f"python3 $HOME/x/runway.py --brief --hooks-version {ih.HOOKS_VERSION}"}]}]
        self.assertEqual(ih.problems(settings, plugin=False), [])

    def test_nothing_installed_lists_every_required_event(self):
        self.assertEqual(ih.problems({}, plugin=False),
                         ["SessionStart: missing", "PostModelSwitch: missing"])


class EndToEnd(unittest.TestCase):
    """Run the script as a subprocess, the way a hook does."""

    def run_script(self, args, stdin="", home=None, scripts=SCRIPTS, env_extra=None):
        import subprocess
        env = dict(os.environ, HOME=str(home) if home else os.environ["HOME"])
        env.pop("RUNWAY_CONTEXT_LIMIT", None)
        env.pop("CLAUDE_CODE_SESSION_ID", None)
        env.update(env_extra or {})
        return subprocess.run([rw.sys.executable, str(scripts / "runway.py"), *args],
                              input=stdin, capture_output=True, text=True, timeout=60, env=env)

    @staticmethod
    def standalone(root):
        """Copy the scripts into a layout with no plugin hooks.json, as a standalone skill."""
        import shutil
        target = root / "skills" / "runway" / "scripts"
        target.mkdir(parents=True)
        for name in ("runway.py", "install-hooks.py"):
            shutil.copy2(SCRIPTS / name, target / name)
        return target

    def test_armed_without_a_session_warns_and_still_exits_zero(self):
        with TemporaryDirectory() as tmp:
            done = self.run_script(["--armed", "2026-09-15 02:22"], "", Path(tmp))
            self.assertEqual(done.returncode, 0)
            self.assertIn("needs a session id", done.stderr)
            self.assertFalse((Path(tmp) / ".claude" / "runway" / "state.json").exists())

    def test_armed_records_per_bucket(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            done = self.run_script(["--armed", "2026-09-15 02:22", "--bucket", "session",
                                    "--session", "s1"], "", home)
            self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))
            state = json.loads((home / ".claude" / "runway" / "state.json").read_text())
            self.assertEqual(state["armed"]["s1"], {"session": "2026-09-15 02:22"})

    def test_a_plugin_install_never_self_installs(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            done = self.run_script(["--json"], "", home)
            self.assertNotIn("wired them", done.stderr)
            self.assertFalse((home / ".claude" / "settings.json").exists())

    def test_the_installer_refuses_inside_the_plugin(self):
        import subprocess
        with TemporaryDirectory() as tmp:
            settings = Path(tmp) / "settings.json"
            done = subprocess.run([rw.sys.executable, str(SCRIPTS / "install-hooks.py"),
                                   "--settings", str(settings)],
                                  capture_output=True, text=True, timeout=30)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn("ship with the plugin", done.stderr)
            self.assertFalse(settings.exists())

    def test_record_model_prints_nothing_and_caches(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            payload = json.dumps({"hook_event_name": "PostModelSwitch", "session_id": "s1",
                                  "to_model": "claude-haiku-4-5"})
            done = self.run_script(["--record-model"], payload, home)
            self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))
            state = json.loads((home / ".claude" / "runway" / "state.json").read_text())
            self.assertEqual(state["models"]["s1"], "claude-haiku-4-5")

    def test_a_manual_run_wires_missing_hooks(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            done = self.run_script(["--json"], "", home, self.standalone(home / "copy"))
            self.assertIn("wired them", done.stderr)
            settings = json.loads((home / ".claude" / "settings.json").read_text())
            self.assertEqual(set(settings["hooks"]),
                             {"SessionStart", "UserPromptSubmit", "PostModelSwitch"})

    def test_the_install_notice_keeps_json_parseable(self):
        with TemporaryDirectory() as tmp:
            done = self.run_script(["--json"], "", Path(tmp), self.standalone(Path(tmp) / "c"))
            self.assertIn("wired them", done.stderr)
            self.assertNotIn("wired them", done.stdout)
            self.assertIn("level", json.loads(done.stdout))

    def test_no_self_install_leaves_settings_alone(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            done = self.run_script(["--json", "--no-self-install"], "", home,
                                   self.standalone(home / "copy"))
            self.assertNotIn("wired them", done.stdout + done.stderr)
            self.assertFalse((home / ".claude" / "settings.json").exists())

    def test_brief_never_self_installs(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            self.run_script(["--brief"], "", home, self.standalone(home / "copy"))
            self.assertFalse((home / ".claude" / "settings.json").exists())

    def session_start(self, home, scripts=SCRIPTS):
        payload = json.dumps({"hook_event_name": "SessionStart", "session_id": "s1",
                              "model": "claude-opus-5[1m]"})
        return self.run_script(["--brief", "--cwd", "/tmp/proj"], payload, home, scripts)

    def test_a_standalone_session_start_reports_missing_hooks(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            done = self.session_start(home, self.standalone(home / "copy"))
            self.assertIn("runway SETUP:", done.stdout)
            self.assertIn("SessionStart: missing", done.stdout)
            self.assertNotIn("no transcript", done.stdout)

    def test_a_plugin_session_start_prints_no_setup_line(self):
        with TemporaryDirectory() as tmp:
            done = self.session_start(Path(tmp))
            self.assertNotIn("runway SETUP:", done.stdout)

    def test_a_manual_run_repairs_an_outdated_install(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            copy = self.standalone(home / "copy")
            (home / ".claude").mkdir()
            stale = {"hooks": {event: [{"hooks": [{"type": "command",
                                                   "command": f'"{copy / "runway.py"}" --brief'}]}]
                               for event in ("SessionStart", "PostModelSwitch")}}
            (home / ".claude" / "settings.json").write_text(json.dumps(stale))
            done = self.run_script(["--json"], "", home, copy)
            self.assertIn("wired them", done.stderr)
            settings = json.loads((home / ".claude" / "settings.json").read_text())
            for groups in settings["hooks"].values():
                self.assertIn("--hooks-version", groups[0]["hooks"][0]["command"])

    def test_ack_without_a_wake_uses_the_last_checked_one(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            state = home / ".claude" / "runway" / "state.json"
            state.parent.mkdir(parents=True)
            state.write_text(json.dumps({"wakes": {"weekly": "2099-01-01 00:02"}}))
            done = self.run_script(["--ack", "--bucket", "weekly", "--session", "s1"], "", home)
            self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))
            saved = json.loads(state.read_text())
            self.assertEqual(saved["armed"]["s1"], {"weekly": {"ack": "2099-01-01 00:02"}})

    def test_ack_with_nothing_to_go_on_warns_and_records_nothing(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            done = self.run_script(["--ack", "--bucket", "weekly", "--session", "s1"], "", home)
            self.assertEqual(done.returncode, 0)
            self.assertIn("--ack needs", done.stderr)
            self.assertFalse((home / ".claude" / "runway" / "state.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
