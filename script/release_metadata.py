#!/usr/bin/env python3
"""Read release identities or allocate the next Shanghai-date build number."""
import argparse
from datetime import datetime
import fcntl
import json
import pathlib
import re
from zoneinfo import ZoneInfo

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_release(root=ROOT):
    release = json.loads((root / 'Resources/Release.json').read_text())
    if not re.fullmatch(r'\d+\.\d+\.\d+', release['version']):
        raise ValueError('Marketing version must have three numeric components.')
    if not re.fullmatch(r'[1-9]\d*', release['build']):
        raise ValueError('Build number must be a positive integer string.')
    config = (root / 'Config/Release.xcconfig').read_text()
    for key, value in [('MARKETING_VERSION', release['version']), ('CURRENT_PROJECT_VERSION', release['build'])]:
        if re.findall(r'^' + key + r'\s*=\s*(\S+)\s*$', config, re.MULTILINE) != [value]:
            raise ValueError(f'{key} must match Resources/Release.json.')
    return release


def metadata(release):
    version, build = release['version'], release['build']
    tag = 'build-' + build
    archive = f'Upovi-{version}-{build}.zip'
    prefix = f'https://github.com/WillSuo-Github/Upovi/releases/download/{tag}/'
    return {'version': version, 'build': build, 'tag': tag, 'archive': archive,
            'download-prefix': prefix, 'download-url': prefix + archive}


def next_build(current, today):
    if not re.fullmatch(r'[1-9]\d*', current):
        raise ValueError('Current build must be a positive integer string.')
    date = today.strftime('%Y%m%d')
    build = str(max(int(date + '0001'), int(current) + 1))
    if len(build) != 12 or build[:8] != date:
        raise ValueError('Cannot allocate a newer build for this Shanghai date; check the clock or daily counter.')
    return build


def bump_build(root=ROOT, today=None, dry_run=False):
    # One shared lock also prevents simultaneous release preparations from reusing a build.
    lock_dir = root / '.local'
    lock_dir.mkdir(parents=True, exist_ok=True)
    with (lock_dir / 'build-number.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        release = load_release(root)
        release['build'] = next_build(release['build'], today or datetime.now(ZoneInfo('Asia/Shanghai')).date())
        if not dry_run:
            config_path = root / 'Config/Release.xcconfig'
            config = re.sub(r'^CURRENT_PROJECT_VERSION\s*=.*$', 'CURRENT_PROJECT_VERSION = ' + release['build'],
                            config_path.read_text(), flags=re.MULTILINE)
            (root / 'Resources/Release.json').write_text(json.dumps(release, indent=2) + '\n')
            config_path.write_text(config)
        return metadata(release)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['show', 'bump-build'])
    parser.add_argument('--field', choices=['version', 'build', 'tag', 'archive', 'download-prefix', 'download-url'])
    parser.add_argument('--dry-run', action='store_true')
    options = parser.parse_args()
    try:
        result = bump_build(dry_run=options.dry_run) if options.action == 'bump-build' else metadata(load_release())
    except (ValueError, OSError, KeyError) as error:
        parser.exit(2, str(error) + '\n')
    print(result[options.field] if options.field else json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
