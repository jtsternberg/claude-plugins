import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
import recurrence


class RecurrenceTest(unittest.TestCase):
    def test_ninety_minutes_uses_two_crons_with_exact_daily_spacing(self):
        result = recurrence.plan("2026-11-13T16:30:00-05:00", 5400)
        self.assertEqual(len(result["cron"]), 2)
        times = []
        for expression in result["cron"]:
            minute, hours, *_ = expression.split()
            times.extend(int(hour) * 60 + int(minute) for hour in hours.split(","))
        times.sort()
        self.assertIn(16 * 60 + 30, times)
        self.assertEqual(len(times), 16)
        wrapped = times[1:] + [times[0] + 1440]
        self.assertTrue(all(b - a == 90 for a, b in zip(times, wrapped)))

    def test_rejects_unrepresentable_cadence_instead_of_rounding(self):
        for interval in (0, -60, 30, 61, 420, 5401, 9000, 172800):
            with self.assertRaises(ValueError):
                recurrence.plan("2026-11-13T16:30:00-05:00", interval)

    def test_every_minute_fits_in_one_native_job(self):
        result = recurrence.plan("2026-11-13T16:30:00-05:00", 60)
        self.assertEqual(len(result["cron"]), 1)
        minutes, hours, *_ = result["cron"][0].split()
        self.assertEqual(set(map(int, minutes.split(","))), set(range(60)))
        self.assertEqual(set(map(int, hours.split(","))), set(range(24)))

    def test_requires_timezone(self):
        with self.assertRaisesRegex(ValueError, "UTC offset"):
            recurrence.plan("2026-11-13T16:30:00", 3600)


if __name__ == "__main__":
    unittest.main()
