import copy
import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'compatibility/propose_bindings.py'
SPEC = importlib.util.spec_from_file_location('bindings', SCRIPT)
bindings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bindings)


class BindingReviewTests(unittest.TestCase):
    def fixture(self):
        old = dict(caseToken='app', bundleID='org.test.App', oldSignatureVerified=True, oldTeamID='ABCDE12345',
                   fromVersion='1', oldBuild='1', stage='source', sourceStatus='unsupported', checkedSources=[],
                   sourceChecks=[], evidence='cases/app/result.json')
        current = dict(token='app', payloadVerified=True, temporaryCopiesRemoved=True, sourceSHA256='a' * 64,
                       applications=[dict(bundleID='org.test.App', teamID='ABCDE12345', application='App.app', version='2', build='2')],
                       evidence='payloads/app/result.json')
        report = dict(generatedAt='2026-11-05', latestCases=[old], latestPayloadInspections=[current])
        cask = dict(token='app', homepage='https://example.org/', artifacts=[{'app': ['App.app']}, {'zap': [{'trash': '~/Library/Preferences/org.test.App.plist'}]}])
        return report, [cask], {'entries': []}

    def test_proposals_are_not_upgraded_into_verified_successes(self):
        result = bindings.proposals(*self.fixture())
        self.assertEqual(len(result['readyForReview']), 1)
        self.assertTrue(result['readyForReview'][0]['reviewRequired'])
        self.assertFalse(result['readyForReview'][0]['upgradeVerified'])

    def test_different_developer_and_manual_rollout_are_held(self):
        args = self.fixture()
        args[0]['latestPayloadInspections'][0]['applications'][0]['teamID'] = 'OTHER12345'
        result = bindings.proposals(*args)
        self.assertFalse(result['readyForReview'])
        self.assertEqual(result['held'][0]['reason'], 'current-identity-or-developer-differs')
        args = self.fixture()
        args[0]['latestCases'][0]['sourceChecks'] = [{'source': 'electron', 'outcome': 'manual'}]
        self.assertFalse(bindings.proposals(*args)['readyForReview'])

    def test_missing_exact_identity_and_nonstandard_installers_cannot_be_promoted(self):
        args = self.fixture()
        args[1][0]['artifacts'] = [{'app': ['App.app']}]
        self.assertFalse(bindings.proposals(*args)['readyForReview'])
        args = self.fixture()
        args[1][0]['artifacts'].append({'installer': {'manual': 'Install.app'}})
        self.assertFalse(bindings.proposals(*args)['readyForReview'])

    def test_unchanged_bundle_versions_and_nonboolean_proofs_cannot_be_promoted(self):
        args = self.fixture()
        app = args[0]['latestPayloadInspections'][0]['applications'][0]
        app.update(version='1', build='1')
        self.assertFalse(bindings.proposals(*args)['readyForReview'])
        args = self.fixture()
        args[0]['latestCases'][0]['oldSignatureVerified'] = 'true'
        self.assertFalse(bindings.proposals(*args)['readyForReview'])

    def test_changed_build_with_constant_display_version_requires_a_compatible_source_model(self):
        args = self.fixture()
        args[0]['latestPayloadInspections'][0]['applications'][0].update(version='1', build='1.2')
        args[1][0]['version'] = '1.2'
        result = bindings.proposals(*args)
        self.assertFalse(result['readyForReview'])
        self.assertEqual(result['held'][0]['reason'], 'constant-display-version-needs-a-reviewed-build-version-provider')
        args[1][0]['version'] = '1,1.2'
        self.assertEqual(len(bindings.proposals(*args)['readyForReview']), 1)


if __name__ == '__main__':
    unittest.main()
