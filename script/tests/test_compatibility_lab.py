import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'compatibility/lab.py'
SPEC = importlib.util.spec_from_file_location('compatibility_lab', SCRIPT)
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


def row(token, ids=None, app=True, disabled=False, url='https://example.org/a.zip'):
    return {'token': token, 'disabled': disabled, 'declaredAppNames': ['App.app'] if app else [],
            'declaredBundleIDs': ids or [], 'platforms': [{'architecture': 'arm64', 'macOSMajor': 27,
             'checksumDescriptorAvailable': True, 'version': '2', 'url': url}]}


class CompatibilityLabTests(unittest.TestCase):
    def test_explicit_campaign_selection_preserves_requested_hash_and_pinned_reproduction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp).resolve()
            requested = root / 'old-probe'; requested.write_text('old immutable test binary')
            selected = root / 'builds/new/compatibility-probe'; selected.parent.mkdir(parents=True)
            selected.write_text('new immutable test binary')
            lab.write_json(selected.parent / 'build-manifest.json', {'binarySHA256': lab.sha256(selected)})
            policy = {'schemaVersion': 1, 'effectiveProbe': 'builds/new/compatibility-probe',
                      'effectiveProbeSHA256': lab.sha256(selected), 'replaceRequestedProbeSHA256': [lab.sha256(requested)]}
            lab.write_json(root / 'campaign-probe-selection.json', policy)
            actual, details = lab.campaign_probe(root, requested)
            self.assertEqual(actual, selected)
            self.assertEqual(details['requestedProbeSHA256'], lab.sha256(requested))
            self.assertEqual(details['probeSelectionPolicySHA256'], lab.sha256(root / 'campaign-probe-selection.json'))
            self.assertEqual(lab.campaign_probe(root, requested, pinned=True)[0], requested)
            other = root / 'other-probe'; other.write_text('not explicitly selected')
            self.assertEqual(lab.campaign_probe(root, other)[0], other)

    def test_campaign_selection_rejects_tampering_and_paths_outside_its_build_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp).resolve()
            requested = root / 'old-probe'; requested.write_text('old')
            selected = root / 'builds/new/compatibility-probe'; selected.parent.mkdir(parents=True); selected.write_text('new')
            lab.write_json(selected.parent / 'build-manifest.json', {'binarySHA256': lab.sha256(selected)})
            policy = {'schemaVersion': 1, 'effectiveProbe': 'builds/new/compatibility-probe',
                      'effectiveProbeSHA256': lab.sha256(selected), 'replaceRequestedProbeSHA256': [lab.sha256(requested)]}
            lab.write_json(root / 'campaign-probe-selection.json', policy)
            selected.write_text('modified after selection')
            with self.assertRaises(ValueError): lab.campaign_probe(root, requested)
            with self.assertRaises(ValueError): lab.validated_campaign_probe(root, requested)
            selected.unlink(); selected.symlink_to(requested)
            with self.assertRaises(ValueError): lab.campaign_probe(root, requested)

    def test_inventory_excludes_fonts_disabled_and_version_variants(self):
        rows = [row('app', ['org.test.App', 'org.test.Helper']), row('other', ['org.test.App']),
                row('app@beta'), row('disabled', disabled=True), row('font-a', app=False, url=''),
                row('package', app=False, url='https://example.org/a.pkg?version=2')]
        totals, queue = lab.inventory(rows, {'items': [{'cask': 'other', 'count': '1,234'}]}, 27)
        self.assertEqual(totals['activeStableAppOrPackageCandidates'], 3)
        self.assertEqual(totals['activeStableDirectAppCandidates'], 2)
        self.assertEqual(totals['identifiersSharedByMultipleCandidates'], 1)
        self.assertEqual(totals['upgradeVerifiedApps'], 0)
        self.assertEqual(queue[0]['token'], 'other')
        self.assertTrue(all(item['upgradeVerified'] is False for item in queue))

    def test_no_partial_upgrade_can_pass(self):
        result = {name: True for name in ['oldSignatureVerified', 'sourceVerified', 'payloadVerified',
                  'installationPassed', 'postInstallCurrent', 'restorePassed', 'upgradeVerified', 'temporaryCopiesRemoved']}
        result['stage'] = 'complete'
        self.assertTrue(lab.upgrade_passed(result))
        for key in list(result):
            if key == 'stage':
                continue
            self.assertFalse(lab.upgrade_passed({**result, key: False}), key)
            self.assertFalse(lab.upgrade_passed({**result, key: 'true'}), key)

    def test_root_rejects_daily_app_path_symlink_and_parent_escape(self):
        with self.assertRaises(ValueError):
            lab.private_root('/Applications')
        with tempfile.TemporaryDirectory() as temp:
            repo = pathlib.Path(temp).resolve()
            with patch.object(lab, 'REPOSITORY', repo):
                local = repo / '.local'
                local.mkdir()
                (local / 'linked').symlink_to(repo, target_is_directory=True)
                for path in [local, local / 'linked/test', local / '../outside']:
                    with self.assertRaises(ValueError):
                        lab.private_root(path)
                self.assertEqual(lab.private_root(local / 'safe'), local / 'safe')

    def test_rejects_insecure_and_credential_urls(self):
        for value in ['http://example.org/a.zip', 'https://user:secret@example.org/a.zip',
                      'file:///Applications/App.app', 'https://example.org/a.zip#secret']:
            with self.assertRaises(ValueError):
                lab.https_url(value)

    def test_curl_budget_errors_are_not_compatibility_failures(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'archive'
            for code in [56, 63]:
                completed = subprocess.CompletedProcess([], code, stdout='', stderr='curl: Maximum file size exceeded')
                with patch.object(lab.subprocess, 'run', return_value=completed):
                    with self.assertRaises(lab.DownloadBudgetExceeded) as error:
                        lab.download('https://example.org/archive.dmg', path, 100)
                    self.assertEqual(error.exception.failure_class, 'packageByteBudget')
                    self.assertFalse(path.with_suffix('.partial').exists())
        self.assertEqual(lab.archive_failure(subprocess.CalledProcessError(22, ['curl']))['failureClass'], 'httpRejected')
        self.assertEqual(lab.archive_failure(lab.ArchiveIntegrityMismatch('private error text'))['failureClass'], 'archiveIntegrityRejected')
        self.assertNotIn('private error text', str(lab.archive_failure(lab.ArchiveIntegrityMismatch('private error text'))))

    def test_resume_requires_recent_identical_inputs_and_a_full_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            case = root / 'cases' / 'test-1'
            case.mkdir(parents=True)
            entry = dict(token='test', bundleID='org.test.App', oldVersion='1', oldURL='https://example.org/1.zip')
            lab.write_json(case / 'input.json', {**entry, 'startedAt': lab.now(), 'catalogSHA256': 'catalog', 'probeSHA256': 'probe'})
            result = {name: True for name in ['oldSignatureVerified', 'sourceVerified', 'payloadVerified',
                      'installationPassed', 'postInstallCurrent', 'restorePassed', 'upgradeVerified', 'temporaryCopiesRemoved']}
            result['stage'] = 'complete'
            lab.write_json(case / 'result.json', result)
            self.assertTrue(lab.resumable_success(root, entry, 'catalog', 'probe'))
            self.assertFalse(lab.resumable_success(root, entry, 'changed', 'probe'))
            self.assertFalse(lab.resumable_success(root, entry, 'catalog', 'changed'))
            self.assertFalse(lab.resumable_success(root, {**entry, 'oldVersion': '0'}, 'catalog', 'probe'))
            lab.write_json(case / 'result.json', {**result, 'restorePassed': False})
            self.assertFalse(lab.resumable_success(root, entry, 'catalog', 'probe'))

    def test_resume_does_not_hide_a_newer_failure_behind_an_older_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            entry = dict(token='test', bundleID='org.test.App', oldVersion='1', oldURL='https://example.org/1.zip')
            result = {name: True for name in ['oldSignatureVerified', 'sourceVerified', 'payloadVerified',
                      'installationPassed', 'postInstallCurrent', 'restorePassed', 'upgradeVerified', 'temporaryCopiesRemoved']}
            result['stage'] = 'complete'
            for number in [1, 2]:
                folder = root / 'cases' / ('test-' + str(number))
                folder.mkdir(parents=True)
                timestamp = (lab.dt.datetime.now(lab.dt.timezone.utc) - lab.dt.timedelta(minutes=3 - number)).isoformat()
                lab.write_json(folder / 'input.json', {**entry, 'startedAt': timestamp, 'catalogSHA256': 'catalog', 'probeSHA256': 'probe'})
                lab.write_json(folder / 'result.json', result if number == 1 else {**result, 'restorePassed': False})
            self.assertFalse(lab.resumable_success(root, entry, 'catalog', 'probe'))

    def test_duplicate_attempts_do_not_add_verified_apps_and_failure_stays_visible(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / 'cases').mkdir()
            lab.write_json(root / 'audit.json', {'rows': []})
            lab.write_json(root / 'inputs.json', {'inputs': []})
            lab.write_json(root / 'homebrew-popularity-365d.json', {'items': [], 'start_date': 'a', 'end_date': 'b'})
            base = {name: True for name in ['oldSignatureVerified', 'sourceVerified', 'payloadVerified',
                    'installationPassed', 'postInstallCurrent', 'restorePassed', 'upgradeVerified', 'temporaryCopiesRemoved']}
            base.update(bundleID='org.test.App', architecture='arm64', hostOS='macOS 27', stage='complete', terminal=True)
            for index, result in enumerate([{**base, 'testedAt': '1'}, {**base, 'testedAt': '2'},
                    {**base, 'architecture': 'x86_64', 'testedAt': '3'},
                    {**base, 'stage': 'prepare', 'upgradeVerified': False, 'testedAt': '4'}]):
                folder = root / 'cases' / str(index)
                folder.mkdir()
                lab.write_json(folder / 'result.json', result)
            lab.report(root)
            report = lab.load(root / 'report.json')
            self.assertEqual(report['totals']['upgradeAttempts'], 4)
            self.assertEqual(report['totals']['upgradeVerifiedApps'], 1)
            self.assertEqual(report['totals']['latestFailedOrBlockedCases'], 1)
            self.assertEqual(len(report['latestCases']), 2)

    def test_public_export_excludes_private_errors_paths_and_log_content(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            value = {key: {} for key in ['totals', 'inputProvenance', 'payloadBlockerClasses']}
            value.update(schemaVersion=1, generatedAt='now', popularityWindow=['a', 'b'], countingPolicy='separate levels', scope='isolated')
            value['latestCases'] = [{'bundleID': 'org.test.App', 'error': 'private-secret', 'path': '/Users/private-secret', 'rawLog': 'private-secret'}]
            value['latestPayloadInspections'] = [{'token': 'test', 'error': 'private-secret', 'rawLog': 'private-secret'}]
            lab.write_json(root / 'report.json', value)
            (root / 'swift-tests.log').write_text("Executed 4 tests, with 0 failures\nTest Suite 'All tests' failed\n")
            with patch.object(lab.subprocess, 'check_output', side_effect=['a' * 40, b' M source']):
                lab.export_evidence(root, root / 'export.json')
            exported = (root / 'export.json').read_text()
            self.assertNotIn('private-secret', exported)
            self.assertEqual(lab.load(root / 'export.json')['latestCases'], [{'bundleID': 'org.test.App'}])
            self.assertNotIn('swift-tests.log', lab.load(root / 'export.json')['validationReports'])

    def test_beta_acceptance_keeps_stable_failure_visible_and_counts_one_app(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / 'cases').mkdir()
            lab.write_json(root / 'audit.json', {'rows': []})
            lab.write_json(root / 'inputs.json', {'inputs': []})
            lab.write_json(root / 'homebrew-popularity-365d.json', {'items': [], 'start_date': 'a', 'end_date': 'b'})
            base = {name: True for name in ['oldSignatureVerified', 'sourceVerified', 'payloadVerified',
                    'installationPassed', 'postInstallCurrent', 'restorePassed', 'upgradeVerified', 'temporaryCopiesRemoved']}
            base.update(bundleID='org.test.App', architecture='arm64', hostOS='macOS 27', stage='complete', terminal=True)
            for channel in ['stable', 'beta']:
                folder = root / 'cases' / channel
                folder.mkdir()
                record = {**base, 'releaseChannel': channel, 'testedAt': lab.now()}
                if channel == 'stable':
                    record.update(stage='source', upgradeVerified=False)
                lab.write_json(folder / 'result.json', record)
            lab.report(root)
            result = lab.load(root / 'report.json')
            self.assertEqual(result['totals']['upgradeVerifiedApps'], 1)
            self.assertEqual(result['totals']['latestFailedOrBlockedCases'], 1)
            self.assertEqual(len(result['latestCases']), 2)


if __name__ == '__main__':
    unittest.main()
