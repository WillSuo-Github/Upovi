import hashlib
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'compatibility'))
import external_appcasts


class ExternalFeedResearchTests(unittest.TestCase):
    def test_only_exact_immutable_nonfixture_stable_blobs_become_unverified_research_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory).resolve()
            root = repo / '.local/lab'
            blobs = root / 'github-appcast-blobs'
            blobs.mkdir(parents=True)
            content = '<rss><channel>Public research input</channel></rss>\n'
            data = content.encode()
            sha = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            base = {'repository': 'publisher/application', 'description': 'A public macOS application',
                    'path': 'appcast.xml', 'blobSHA': sha, 'sourceURL': 'https://github.com/publisher/application/blob/commit/appcast.xml'}
            external_appcasts.lab.write_json(blobs / (sha + '.json'), {'content': content})
            bad = 'b' * 40
            external_appcasts.lab.write_json(blobs / (bad + '.json'), {'content': 'not the requested immutable blob'})
            external_appcasts.lab.write_json(root / 'github-appcast-code-leads.json', {'leads': [base, base | {'repository': 'other/copy'},
                base | {'blobSHA': bad, 'path': 'untrusted.xml'}]})
            with patch.object(external_appcasts.lab, 'REPOSITORY', repo):
                external_appcasts.prepare(root)
            records = external_appcasts.lab.load(root / 'external-appcasts/inputs.json')
            self.assertEqual(len(records), 1)
            self.assertTrue(records[0]['productReviewRequired'])
            self.assertFalse(records[0]['upgradeVerified'])
            self.assertEqual((root / 'external-appcasts' / records[0]['file']).read_bytes(), data)
            self.assertEqual(len(external_appcasts.lab.load(root / 'external-appcasts/held.json')), 1)

    def test_beta_files_and_framework_examples_remain_research_holds(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory).resolve()
            root = repo / '.local/lab'
            blobs = root / 'github-appcast-blobs'; blobs.mkdir(parents=True)
            leads = []
            for i, name in enumerate(['tests/appcast.xml', 'releases/appcast-beta.xml', 'examples/feed.xml']):
                content = '<rss>' + str(i) + '</rss>'
                data = content.encode(); sha = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
                leads.append({'repository': 'publisher/app', 'description': '', 'path': name, 'blobSHA': sha, 'sourceURL': 'https://github.com/publisher/app'})
                external_appcasts.lab.write_json(blobs / (sha + '.json'), {'content': content})
            external_appcasts.lab.write_json(root / 'github-appcast-code-leads.json', {'leads': leads})
            with patch.object(external_appcasts.lab, 'REPOSITORY', repo): external_appcasts.prepare(root)
            self.assertEqual(external_appcasts.lab.load(root / 'external-appcasts/inputs.json'), [])
            self.assertEqual(len(external_appcasts.lab.load(root / 'external-appcasts/held.json')), 3)


if __name__ == '__main__':
    unittest.main()
