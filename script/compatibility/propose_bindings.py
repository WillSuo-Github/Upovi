#!/usr/bin/env python3
"""Produce review proposals from actual signed baselines and verified current payloads.

No catalog is changed. Exact upstream identity references remain mandatory, and
explicit manual/vendor rollout restrictions are never converted into proposals.
"""
import argparse
import json
import pathlib


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)


def proposals(report, catalog, reviewed):
    casks = {c['token']: c for c in catalog}
    existing = {r['bundleID'] for r in reviewed['entries']}
    inspected = {r['token']: r for r in report['latestPayloadInspections']}
    ready, inspect, held = [], [], []
    for old in report['latestCases']:
        token, bundle = old['caseToken'], old['bundleID']
        if old.get('upgradeVerified') or old.get('oldSignatureVerified') is not True or old.get('stage') != 'source':
            continue
        if bundle in existing or token not in casks or old.get('sourceStatus') != 'unsupported':
            continue
        if old.get('checkedSources') or any(x.get('outcome') == 'manual' for x in old.get('sourceChecks', [])):
            continue
        # Older probe format did not store all fixed source outcomes.
        if any(text in old.get('error', '') for text in ['特殊渠道', '分批发布', '来源签名限制']):
            held.append({'token': token, 'reason': 'explicit-vendor-restriction'})
            continue
        cask = casks[token]
        if cask.get('disabled') or '@' in token or any(any(k in a for k in ['installer', 'pkg', 'stage_only']) for a in cask.get('artifacts', [])):
            held.append({'token': token, 'reason': 'nonstandard-installation'})
            continue
        artifacts = set(strings(cask.get('artifacts', [])))
        artifacts |= {pathlib.PurePosixPath(x).name for x in list(artifacts)}
        if not artifacts & {bundle, bundle + '.plist', bundle + '.savedState'}:
            held.append({'token': token, 'bundleID': bundle, 'reason': 'no-independent-exact-upstream-identity-reference'})
            continue
        current = inspected.get(token)
        if not current or current.get('payloadVerified') is not True or current.get('temporaryCopiesRemoved') is not True:
            inspect.append(token)
            continue
        matches = [a for a in current.get('applications', []) if a['bundleID'] == bundle and a['teamID'] == old['oldTeamID']]
        if len(matches) != 1:
            held.append({'token': token, 'reason': 'current-identity-or-developer-differs'})
            continue
        app = matches[0]
        if app['version'] == old['fromVersion'] and app['build'] == old.get('oldBuild'):
            held.append({'token': token, 'reason': 'unchanged-bundle-version-identity-needs-a-reviewed-version-provider'})
            continue
        if app['version'] == old['fromVersion'] and str(cask.get('version', '')).split(',', 1)[0] != app['version']:
            held.append({'token': token, 'reason': 'constant-display-version-needs-a-reviewed-build-version-provider'})
            continue
        ready.append({'entry': {'bundleID': bundle, 'application': app['application'], 'cask': token,
                               'homepage': cask['homepage'], 'reviewedAt': report['generatedAt'][:10]},
                      'baselineEvidence': old['evidence'], 'currentEvidence': current['evidence'],
                      'oldVersion': old['fromVersion'], 'oldTeamID': old['oldTeamID'],
                      'currentVersion': app['version'], 'currentTeamID': app['teamID'],
                      'currentSHA256': current['sourceSHA256'], 'reviewRequired': True, 'upgradeVerified': False})
    return {'schemaVersion': 1, 'readyForReview': ready, 'needsPayloadInspection': sorted(set(inspect)), 'held': held}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--reviewed', type=pathlib.Path, default=pathlib.Path('Resources/ReviewedSources.json'))
    parser.add_argument('--output', type=pathlib.Path, required=True)
    options = parser.parse_args()
    def load(path):
        return json.loads(path.read_text())
    result = proposals(load(options.root / 'report.json'), load(options.root / 'homebrew-casks.json'), load(options.reviewed))
    options.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'ready': len(result['readyForReview']), 'needsInspection': result['needsPayloadInspection'], 'held': result['held']}, indent=2))


if __name__ == '__main__':
    main()
