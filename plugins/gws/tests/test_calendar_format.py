"""Tests for calendar-format.py rendering.

Focus: output must never mislead. A deleted event still comes back from
events.get with status "cancelled", and rendering it identically to a live
event reads as "the delete silently failed" — which is exactly how it was
misread once. All-day events likewise must not be rendered as midnight.
"""
import importlib.util
import io
import json
import pathlib
import unittest
from contextlib import redirect_stdout

_HERE = pathlib.Path(__file__).resolve().parent
_FORMAT_PY = _HERE.parent / "scripts" / "calendar-format.py"

_spec = importlib.util.spec_from_file_location("calendar_format", _FORMAT_PY)
calendar_format = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(calendar_format)


def timed(**over):
    e = {
        "id": "evt1",
        "summary": "Standup",
        "status": "confirmed",
        "start": {"dateTime": "2026-09-28T09:00:00-04:00"},
        "end": {"dateTime": "2026-09-28T09:15:00-04:00"},
    }
    e.update(over)
    return e


def all_day(**over):
    e = {
        "id": "evt2",
        "summary": "Offsite",
        "status": "confirmed",
        "start": {"date": "2026-09-28"},
        "end": {"date": "2026-09-30"},
    }
    e.update(over)
    return e


class TestCancelled(unittest.TestCase):
    def test_cancelled_event_is_flagged(self):
        out = calendar_format.format_event(all_day(status="cancelled"), "", "")
        self.assertIn("[CANCELLED]", out)

    def test_confirmed_event_is_not_flagged(self):
        out = calendar_format.format_event(all_day(), "", "")
        self.assertNotIn("[CANCELLED]", out)

    def test_missing_status_is_not_flagged(self):
        e = all_day()
        del e["status"]
        self.assertNotIn("[CANCELLED]", calendar_format.format_event(e, "", ""))

    def test_cancelled_and_declined_both_shown(self):
        e = timed(
            status="cancelled",
            attendees=[{"email": "me@example.com", "self": True,
                        "responseStatus": "declined"}],
        )
        out = calendar_format.format_event(e, "me@example.com", "")
        self.assertIn("[CANCELLED]", out)
        self.assertIn("[DECLINED]", out)

    def test_is_cancelled_predicate(self):
        self.assertTrue(calendar_format.is_cancelled({"status": "cancelled"}))
        self.assertFalse(calendar_format.is_cancelled({"status": "confirmed"}))
        self.assertFalse(calendar_format.is_cancelled({}))


class TestAllDayRendering(unittest.TestCase):
    def test_all_day_start_is_labelled(self):
        out = calendar_format.format_event(all_day(), "", "")
        self.assertIn("2026-09-28 (all-day)", out)

    def test_event_start_prefers_datetime_then_date(self):
        self.assertEqual(
            calendar_format.event_start(timed()), "2026-09-28T09:00:00-04:00")
        self.assertEqual(calendar_format.event_start(all_day()), "2026-09-28")
        self.assertEqual(calendar_format.event_start({}), "")

    def test_all_day_is_not_rendered_as_midnight(self):
        out = calendar_format.format_event(all_day(), "", "")
        self.assertNotIn("12:00 AM", out)


class TestJsonMode(unittest.TestCase):
    """--json output is what agents branch on, so the flags must be present."""

    def _run_json(self, event):
        import sys
        argv, stdin = sys.argv, sys.stdin
        sys.argv = ["calendar-format.py", "--json", "--mode", "get"]
        sys.stdin = io.StringIO(json.dumps(event))
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                calendar_format.main()
        finally:
            sys.argv, sys.stdin = argv, stdin
        return json.loads(buf.getvalue())

    def test_json_carries_cancelled_true(self):
        self.assertTrue(self._run_json(all_day(status="cancelled"))["cancelled"])

    def test_json_carries_cancelled_false(self):
        self.assertFalse(self._run_json(all_day())["cancelled"])

    def test_json_all_day_bounds_are_dates(self):
        row = self._run_json(all_day())
        self.assertEqual(row["start"], "2026-09-28")
        self.assertEqual(row["end"], "2026-09-30")


if __name__ == "__main__":
    unittest.main()
