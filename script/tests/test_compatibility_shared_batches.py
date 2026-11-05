import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'compatibility/lab.py'
SPEC = importlib.util.spec_from_file_location('shared_lab', SCRIPT)
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class SharedBatchTests(unittest.TestCase):
    def test_live_lease_prevents_duplicate_batch_and_aborted_work_remains_retryable(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = pathlib.Path(directory).resolve()
            root = repository / '.local/lab'; root.mkdir(parents=True)
            manifest = root / 'batch.json'; lab.write_json(manifest, [{'token': 'unit-input-only'}])
            probe = root / 'probe'; probe.write_text('unit probe, never executed')
            lab.write_json(root / 'homebrew-casks.json', [])
            lab.write_json(root / 'shared-campaign-batches.json', {'schemaVersion': 1, 'manifests': {'batch.json': lab.sha256(manifest)}})
            with patch.object(lab, 'REPOSITORY', repository):
                with self.assertRaises(RuntimeError):
                    with lab.shared_batch(root, manifest, probe, 1) as acquired:
                        self.assertTrue(acquired)
                        with lab.shared_batch(root, manifest, probe, 1) as other:
                            self.assertFalse(other)
                        raise RuntimeError('Interrupted before all inputs processed')
                self.assertEqual(list((root / 'shared-batches').glob('*.processed.json')), [])
                with lab.shared_batch(root, manifest, probe, 1) as acquired: self.assertTrue(acquired)
                with lab.shared_batch(root, manifest, probe, 1) as acquired: self.assertFalse(acquired)
                probe.write_text('new unit engine requires fresh processing')
                with lab.shared_batch(root, manifest, probe, 1) as acquired: self.assertTrue(acquired)
            for marker in (root / 'shared-batches').glob('*.processed.json'):
                self.assertEqual(lab.load(marker)['status'], 'inputsProcessed')
                self.assertNotIn('upgradeVerified', lab.load(marker))

    def test_changed_or_partial_shared_manifests_cannot_claim_processing_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = pathlib.Path(directory).resolve()
            root = repository / '.local/lab'; root.mkdir(parents=True)
            manifest = root / 'batch.json'; lab.write_json(manifest, [{'token': 'unit-input-only'}])
            probe = root / 'probe'; probe.write_text('unit input')
            lab.write_json(root / 'homebrew-casks.json', [])
            lab.write_json(root / 'shared-campaign-batches.json', {'schemaVersion': 1, 'manifests': {'batch.json': lab.sha256(manifest)}})
            with patch.object(lab, 'REPOSITORY', repository):
                with self.assertRaises(ValueError):
                    with lab.shared_batch(root, manifest, probe, 0): pass
                lab.write_json(manifest, [{'token': 'changed-input'}])
                with self.assertRaises(ValueError):
                    with lab.shared_batch(root, manifest, probe, 1): pass


if __name__ == '__main__':
    unittest.main()
