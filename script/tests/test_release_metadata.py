import datetime
from concurrent.futures import ThreadPoolExecutor
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from release_metadata import bump_build, load_release, metadata, next_build


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / 'Resources').mkdir()
        (self.root / 'Config').mkdir()
        self.release = self.root / 'Resources/Release.json'
        self.config = self.root / 'Config/Release.xcconfig'
        self.release.write_text(json.dumps({'version': '0.4.10', 'build': '16', 'feedURL': 'https://example.invalid/feed'}))
        self.config.write_text('// Preserve this comment.\nMARKETING_VERSION = 0.4.10\nCURRENT_PROJECT_VERSION = 16\n')
        self.today = datetime.date(2026, 10, 27)

    def test_migrates_legacy_number_to_first_date_build(self):
        self.assertEqual(next_build('16', self.today), '202610270001')

    def test_repeated_builds_increment_and_new_day_resets_counter(self):
        self.assertEqual(next_build('202610270001', self.today), '202610270002')
        self.assertEqual(next_build('202610269999', self.today), '202610270001')

    def test_clock_rollback_and_daily_exhaustion_cannot_decrease_build(self):
        for current in ['202610280001', '202610279999']:
            with self.subTest(current=current), self.assertRaises(ValueError):
                next_build(current, self.today)

    def test_bump_synchronizes_files_without_changing_marketing_version(self):
        first = bump_build(self.root, self.today)
        second = bump_build(self.root, self.today)
        self.assertEqual(first['build'], '202610270001')
        self.assertEqual(second['build'], '202610270002')
        saved = load_release(self.root)
        self.assertEqual(saved['version'], '0.4.10')
        self.assertEqual(saved['feedURL'], 'https://example.invalid/feed')
        self.assertIn('MARKETING_VERSION = 0.4.10\n', self.config.read_text())
        self.assertIn('CURRENT_PROJECT_VERSION = 202610270002\n', self.config.read_text())
        self.assertTrue(self.config.read_text().startswith('// Preserve this comment.'))

    def test_dry_run_does_not_consume_build(self):
        before = (self.release.read_bytes(), self.config.read_bytes())
        self.assertEqual(bump_build(self.root, self.today, dry_run=True)['build'], '202610270001')
        self.assertEqual(before, (self.release.read_bytes(), self.config.read_bytes()))
        self.assertEqual(bump_build(self.root, self.today)['build'], '202610270001')

    def test_configuration_drift_is_rejected_before_modifying_either_file(self):
        self.config.write_text(self.config.read_text().replace('CURRENT_PROJECT_VERSION = 16', 'CURRENT_PROJECT_VERSION = 17'))
        before = (self.release.read_bytes(), self.config.read_bytes())
        with self.assertRaises(ValueError):
            bump_build(self.root, self.today)
        self.assertEqual(before, (self.release.read_bytes(), self.config.read_bytes()))

    def test_same_marketing_version_has_distinct_build_downloads(self):
        first = metadata({'version': '0.4.10', 'build': '202610270001'})
        second = metadata({'version': '0.4.10', 'build': '202610270002'})
        self.assertEqual(first['tag'], 'build-202610270001')
        self.assertEqual(first['archive'], 'Upovi-0.4.10-202610270001.zip')
        self.assertNotEqual(first['download-url'], second['download-url'])
        self.assertEqual(first['version'], second['version'])
        self.assertTrue(first['download-url'].endswith('/build-202610270001/Upovi-0.4.10-202610270001.zip'))

    def test_simultaneous_preparations_allocate_distinct_builds(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            builds = list(pool.map(lambda _: bump_build(self.root, self.today)['build'], range(4)))
        self.assertEqual(sorted(builds), ['202610270001', '202610270002', '202610270003', '202610270004'])
        self.assertEqual(load_release(self.root)['build'], '202610270004')


if __name__ == '__main__':
    unittest.main()
