#!/usr/bin/env python3
"""Process an explicitly selected sequence of isolated acceptance batches.

A completed batch means inputs were processed, never that all apps passed.
Only the lab's full source/install/recheck/restore gates determine app counts.
"""
import argparse
import json
import pathlib
import subprocess
import sys
import uuid

import lab


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--probe', type=pathlib.Path, required=True)
    parser.add_argument('--batch', type=pathlib.Path, action='append', required=True)
    parser.add_argument('--proxy-port', type=int)
    parser.add_argument('--max-old-mb', type=int, default=800)
    options = parser.parse_args()
    root = lab.private_root(options.root)
    probe = options.probe.absolute()
    if probe != probe.resolve() or not probe.is_relative_to(lab.REPOSITORY / '.local'):
        parser.error('Use an immutable probe under repository .local.')
    identifier = uuid.uuid4().hex[:12]
    state_file = root / ('campaign-' + identifier + '.json')
    state = {'schemaVersion': 1, 'startedAt': lab.now(), 'probeSHA256': lab.sha256(probe),
             'status': 'processing', 'batches': [], 'completedBatchesAreNotVerifiedApps': True}
    lab.write_json(state_file, state)
    for manifest in options.batch:
        manifest = manifest.absolute()
        if manifest != manifest.resolve() or not manifest.is_relative_to(root):
            parser.error('Use private batch manifests under the selected lab root.')
        entries = lab.load(manifest)
        if not isinstance(entries, list) or not 1 <= len(entries) <= 50:
            parser.error('Each explicit batch must contain 1-50 cases.')
        item = {'manifest': manifest.name, 'manifestSHA256': lab.sha256(manifest), 'startedAt': lab.now(), 'status': 'processing'}
        state['batches'].append(item)
        lab.write_json(state_file, state)
        command = [sys.executable, str(pathlib.Path(__file__).with_name('lab.py')), '--root', str(root), '--probe', str(probe),
                   'run', '--manifest', str(manifest), '--limit', str(len(entries)), '--max-old-mb', str(options.max_old_mb), '--resume']
        if options.proxy_port:
            command += ['--proxy-port', str(options.proxy_port)]
        log_path = root / (manifest.stem + '-campaign-' + identifier + '.log')
        item['logFile'] = log_path.name
        lab.write_json(state_file, state)
        with log_path.open('x') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        delegated = 'Shared batch skipped:' in log_path.read_text()
        item.update(status='delegated' if result.returncode == 0 and delegated else 'processed' if result.returncode == 0 else 'batchError', exitCode=result.returncode, finishedAt=lab.now())
        lab.write_json(state_file, state)
        print(manifest.name, item['status'], flush=True)
    state.update(status='processed', finishedAt=lab.now())
    lab.write_json(state_file, state)
    lab.report(root)


if __name__ == '__main__':
    main()
