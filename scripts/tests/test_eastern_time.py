"""Force the stdlib Eastern fallback without launching any other test runner."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import importlib.util
import sys
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfoNotFoundError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import eastern_time


class EasternFallbackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.zone_patch = patch.object(eastern_time, 'ZoneInfo', side_effect=ZoneInfoNotFoundError)
        self.zone_patch.start()
        self.addCleanup(self.zone_patch.stop)
        self.zone = eastern_time.eastern_zone()

    def test_boundary_instants(self) -> None:
        cases = [
            ('2026-03-08T06:59:59+00:00', '2026-03-08T01:59:59-05:00', 0),
            ('2026-03-08T07:00:00+00:00', '2026-03-08T03:00:00-04:00', 0),
            ('2026-11-01T05:59:59+00:00', '2026-11-01T01:59:59-04:00', 0),
            ('2026-11-01T06:00:00+00:00', '2026-11-01T01:00:00-05:00', 1),
            ('2026-11-01T07:00:00+00:00', '2026-11-01T02:00:00-05:00', 0),
            ('2026-01-15T17:00:00+00:00', '2026-01-15T12:00:00-05:00', 0),
            ('2026-07-15T16:00:00+00:00', '2026-07-15T12:00:00-04:00', 0),
        ]
        for stamp, expected, fold in cases:
            with self.subTest(stamp=stamp):
                utc = datetime.fromisoformat(stamp)
                local = utc.astimezone(self.zone)
                self.assertEqual(local.isoformat(), expected)
                self.assertEqual(local.fold, fold)
                self.assertEqual(local.astimezone(timezone.utc), utc)

    def test_local_week_boundaries(self) -> None:
        for month, day, hours in [(3, 8, 23), (11, 1, 25)]:
            start = datetime(2026, month, day, tzinfo=self.zone)
            end = start + timedelta(days=1)
            self.assertEqual(end.astimezone(timezone.utc) - start.astimezone(timezone.utc),
                             timedelta(hours=hours))

    def test_prefers_database(self) -> None:
        with patch.object(eastern_time, 'ZoneInfo', return_value=timezone.utc) as factory:
            self.assertIs(eastern_time.eastern_zone(), timezone.utc)
            factory.assert_called_once_with('America/New_York')

    def test_reporting_consumers_load_without_database(self) -> None:
        root = Path(__file__).resolve().parents[2]
        paths = [root / 'scripts/model-router/cost_report.py',
                 root / 'skills/dt-build/scripts/collect-usage.py']
        for index, path in enumerate(paths):
            with self.subTest(path=path):
                name = f'fs66_consumer_{index}'
                spec = importlib.util.spec_from_file_location(name, path)
                module = importlib.util.module_from_spec(spec)
                with patch.dict(sys.modules, {name: module}):
                    spec.loader.exec_module(module)
                self.assertEqual(datetime(2026, 7, 15, tzinfo=module.ET_ZONE).utcoffset(),
                                 timedelta(hours=-4))
                if index == 0:
                    start, end = module.week_bounds_utc(2026, 10)
                    self.assertEqual(end - start, timedelta(hours=167))
                else:
                    self.assertEqual(module.to_et_date('2026-01-15T01:00:00'), '2026-01-14')


if __name__ == '__main__':
    unittest.main()
