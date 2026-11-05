import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'compatibility/discover_pairs.py'
SPEC = importlib.util.spec_from_file_location('discovery', SCRIPT)
discovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(discovery)


class DiscoveryTests(unittest.TestCase):
    def record(self):
        return {'candidate': {'token': 'app', 'bundleIDs': ['org.test.App'], 'tag': 'v2.0', 'asset': 'App-2.0-arm64.dmg'},
                'releases': [{'tag': 'v2.0', 'draft': False, 'prerelease': False, 'assets': []},
                             {'tag': 'v1.0', 'draft': False, 'prerelease': False, 'url': 'https://github.com/a/b/releases/tag/v1.0',
                              'assets': [{'name': 'App-1.0-arm64.dmg', 'url': 'https://github.com/a/b/old.dmg',
                                          'digest': 'sha256:' + 'a' * 64, 'size': 123}]}]}

    def test_keeps_actual_official_url_digest_and_architecture(self):
        result, error = discovery.select_pair(self.record(), 200)
        self.assertIsNone(error)
        self.assertEqual(result['oldURL'], 'https://github.com/a/b/old.dmg')
        self.assertEqual(result['oldSHA256'], 'a' * 64)
        self.assertEqual(result['oldVersion'], '')
        self.assertTrue(result['discoverBaseline'])

    def test_never_replaces_native_archive_with_intel_or_an_ambiguous_asset(self):
        record = self.record()
        record['releases'][1]['assets'][0]['name'] = 'App-1.0-x64.dmg'
        self.assertIsNone(discovery.select_pair(record, 200)[0])
        record = self.record()
        record['releases'][1]['assets'] *= 2
        self.assertEqual(discovery.select_pair(record, 200)[1], 'ambiguous-archive-family')

    def test_prereleases_and_large_archives_are_not_silently_selected(self):
        record = self.record()
        record['releases'][1]['prerelease'] = True
        self.assertIsNone(discovery.select_pair(record, 200)[0])
        self.assertEqual(discovery.select_pair(self.record(), 100)[1], 'old-archive-byte-budget')

    def test_invalid_published_proof_cannot_be_downgraded_to_no_proof(self):
        record = self.record()
        record['releases'][1]['assets'][0]['digest'] = 'sha256:invalid'
        self.assertEqual(discovery.select_pair(record, 200)[1], 'malformed-or-unsupported-published-archive-proof')

    def test_encoded_tag_and_multiple_quit_ids_require_signed_baseline_discovery(self):
        record = self.record()
        record['candidate'].update(tag='production%2Fv2.0', bundleIDs=['org.test.App', 'org.test.App.Helper'])
        record['releases'][0]['tag'] = 'production/v2.0'
        record['releases'][1]['tag'] = 'production/v1.0'
        result, error = discovery.select_pair(record, 200)
        self.assertIsNone(error)
        self.assertEqual(result['bundleID'], '')


if __name__ == '__main__':
    unittest.main()
