#!/usr/bin/env python3
"""Select authentic older archives from cached official GitHub release metadata.

This only creates unverified test inputs. It never executes recipes, invents an
archive URL, changes product trust mappings, or declares an application supported.
"""
import argparse
import json
import pathlib
import re
import urllib.parse


def asset_family(filename, tag):
    values = {tag, tag.removeprefix('v'), tag.rsplit('/', 1)[-1]}
    values.update(re.findall(r'\d+(?:\.\d+){1,4}(?:[ab]\d*)?', tag))
    for value in sorted(values, key=len, reverse=True):
        if value:
            filename = filename.replace(value, '{version}')
    return filename


def select_pair(record, maximum_bytes):
    candidate, releases = record['candidate'], record['releases']
    current_tag = urllib.parse.unquote(candidate['tag'])
    current = next((i for i, r in enumerate(releases) if r['tag'] == current_tag), None)
    if current is None:
        return None, 'current-release-not-in-snapshot'
    if releases[current]['draft'] or releases[current]['prerelease']:
        return None, 'current-release-not-stable'
    family = asset_family(candidate['asset'], current_tag)
    for release in releases[current + 1:]:
        if release['draft'] or release['prerelease']:
            continue
        matching = [a for a in release['assets'] if asset_family(a['name'], release['tag']) == family]
        if len(matching) > 1:
            return None, 'ambiguous-archive-family'
        if len(matching) != 1:
            continue
        asset = matching[0]
        if not 0 < asset['size'] <= maximum_bytes:
            return None, 'old-archive-byte-budget'
        ids = candidate['bundleIDs']
        result = {'token': candidate['token'], 'bundleID': ids[0] if len(ids) == 1 else '',
                  'oldVersion': '', 'discoverBaseline': True,
                  'oldURL': asset['url'], 'oldReleaseURL': release['url'], 'oldReleaseTag': release['tag'],
                  'oldDeclaredBytes': asset['size'], 'cask': candidate['token'],
                  'provenance': 'Actual official upstream release asset; exact archive filename family and architecture; signed baseline identity/version must still be verified.'}
        if asset.get('digest'):
            if not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', asset['digest']):
                return None, 'malformed-or-unsupported-published-archive-proof'
            result['oldSHA256'] = asset['digest'][7:].lower()
        return result, None
    return None, 'no-unambiguous-older-archive'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--maximum-old-mb', type=int, default=800)
    options = parser.parse_args()
    results, blocked = [], []
    for path in sorted(options.metadata.glob('*.json')):
        record = json.loads(path.read_text())
        result, reason = select_pair(record, options.maximum_old_mb * 1024**2)
        if result:
            results.append(result)
        else:
            blocked.append({'token': record['candidate']['token'], 'reason': reason})
    options.output.write_text(json.dumps(results, indent=2) + '\n')
    options.output.with_suffix('.blocked.json').write_text(json.dumps(blocked, indent=2) + '\n')
    print(json.dumps({'unverifiedPairs': len(results), 'blockedDiscovery': blocked}, indent=2))


if __name__ == '__main__':
    main()
