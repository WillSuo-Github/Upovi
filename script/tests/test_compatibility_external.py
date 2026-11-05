import copy
import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'compatibility/lab.py'
SPEC = importlib.util.spec_from_file_location('external_lab', SCRIPT)
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class ExternalAcceptanceTests(unittest.TestCase):
    def fixture(self, root):
        baseline = root / 'external-baselines/research-1'
        baseline.mkdir(parents=True)
        archive = baseline / 'old.archive'
        archive.write_bytes(b'synthetic unit input, never an application acceptance')
        observed = lab.sha256(archive)
        source = {'oldURL': 'https://publisher.invalid/App-1.zip', 'oldEDSignature': 'independent-signature-reference'}
        evidence = source | {'bundleID': 'org.synthetic.App', 'oldVersion': '1.0', 'oldTeamID': 'ABCDE12345',
            'application': 'App.app', 'oldSourceURL': source['oldURL'], 'baselineInspected': True, 'oldSignatureVerified': True,
            'oldEnclosureSignatureVerified': True, 'temporaryCopiesRemoved': True, 'terminal': True, 'bundlePackageType': 'APPL',
            'backgroundOnly': False, 'oldArchiveSHA256': observed, 'upgradeVerified': False}
        lab.write_json(baseline / 'input.json', source)
        lab.write_json(baseline / 'result.json', evidence)
        probe = root / 'builds/probe/compatibility-probe'
        probe.parent.mkdir(parents=True)
        probe.write_text('unit-only probe, not executed')
        lab.write_json(probe.parent / 'build-manifest.json', {'capabilities': ['externalReviewedBaselineV1'], 'binarySHA256': lab.sha256(probe)})
        review = {'schemaVersion': 1, 'productReviewed': True, 'productPurpose': 'Synthetic unit validation',
                  'primaryProductURL': 'https://publisher.invalid/', 'bundleID': evidence['bundleID'], 'application': 'App.app',
                  'teamID': 'ABCDE12345', 'baselineEvidence': str((baseline / 'result.json').relative_to(root))}
        entry = source | {'kind': 'externalReviewedAppcast', 'bundleID': evidence['bundleID'], 'oldVersion': '1.0',
                          'oldObservedSHA256': observed, 'externalReview': review}
        return entry, probe, baseline, archive

    def test_reviewed_baseline_cache_is_an_input_not_an_upgrade_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            entry, probe, baseline, archive = self.fixture(root)
            self.assertEqual(lab.reviewed_external_baseline(root, entry, probe), archive)
            self.assertFalse(lab.upgrade_passed(lab.load(baseline / 'result.json')))
            archive.unlink()
            self.assertIsNone(lab.reviewed_external_baseline(root, entry, probe), 'A replay can redownload the exact observed baseline')

    def test_unreviewed_metadata_changed_signer_and_tampered_cache_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            entry, probe, baseline, archive = self.fixture(root)
            for change in ['unreviewed', 'developer', 'path', 'archive']:
                changed = copy.deepcopy(entry)
                if change == 'unreviewed': changed['externalReview']['productReviewed'] = False
                if change == 'developer': changed['externalReview']['teamID'] = 'OTHER12345'
                if change == 'path': changed['externalReview']['baselineEvidence'] = '../outside/result.json'
                if change == 'archive': archive.write_bytes(b'changed cache')
                with self.assertRaises(ValueError, msg=change): lab.reviewed_external_baseline(root, changed, probe)

    def test_research_or_missing_external_proof_can_never_increment_upgrade_count(self):
        passed = {key: True for key in ['oldSignatureVerified', 'sourceVerified', 'payloadVerified', 'installationPassed',
                                      'postInstallCurrent', 'restorePassed', 'upgradeVerified', 'temporaryCopiesRemoved']}
        passed['stage'] = 'complete'
        self.assertFalse(lab.upgrade_passed(passed | {'caseKind': 'externalAppcastResearch'}))
        self.assertFalse(lab.upgrade_passed(passed | {'caseKind': 'externalReviewedAppcast'}))
        self.assertTrue(lab.upgrade_passed(passed | {'caseKind': 'externalReviewedAppcast',
            'externalProductReviewVerified': True, 'oldEnclosureSignatureVerified': True}))


if __name__ == '__main__':
    unittest.main()
