#!/usr/bin/env python3
"""Prepare public immutable feed leads and inspect authentic old applications.

No product review or upgrade success is generated here. Baselines are never
launched. A small bounded archive cache is retained only for subsequent explicit
product review and full production upgrade acceptance.
"""
import argparse
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import urllib.parse
import uuid

import lab


def prepare(root):
    output = lab.private_root(root / 'external-appcasts')
    (output / 'explicit-acceptance-root').write_text(str(output))
    leads = lab.load(root / 'github-appcast-code-leads.json')['leads']
    records, held, seen = [], [], set()
    for lead in leads:
        blob = lead['blobSHA']
        if not re.fullmatch(r'[a-f0-9]{40}', blob) or blob in seen:
            continue
        seen.add(blob)
        path = root / 'github-appcast-blobs' / (blob + '.json')
        if path.resolve() != path or not path.exists():
            held.append({'blobSHA': blob, 'reason': 'missing-immutable-input'})
            continue
        content = lab.load(path)['content'].encode('utf-8')
        actual = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
        if actual != blob or len(content) > 3_000_000:
            held.append({'blobSHA': blob, 'reason': 'immutable-input-integrity-or-budget'})
            continue
        if re.search(r'(?:^|/)(?:tests?|examples?|samples?|fixtures?)(?:/|$)', lead['path'], re.I) or lead['repository'].lower() == 'sparkle-project/sparkle':
            held.append({'blobSHA': blob, 'reason': 'sample-or-framework-research'})
            continue
        if re.search(r'(?:^|[/_.-])(?:alpha|beta|nightly|preview|dev|test|canary|insiders?|unstable|experimental)(?:[/_.-]|$)', lead['path'], re.I):
            held.append({'blobSHA': blob, 'reason': 'nonstable-research-feed'})
            continue
        token = 'external-' + blob
        file = output / (token + '.xml')
        file.write_bytes(content)
        file.chmod(0o600)
        records.append({'token': token, 'downloaded': True, 'file': file.name, 'sha256': lab.sha256(file),
                        'sourceGitBlobSHA': blob, 'sourceURL': lead['sourceURL'], 'sourceRepository': lead['repository'],
                        'sourceDescription': lead['description'], 'productReviewRequired': True, 'upgradeVerified': False})
    lab.write_json(output / 'inputs.json', records)
    lab.write_json(output / 'held.json', held)
    print({'immutablePublicResearchFeeds': len(records), 'held': len(held), 'verifiedApps': 0})


def inspect(root, probe, limit, budget_mb, maximum_mb, proxy_port):
    if not 1 <= limit <= 30 or not 1 <= maximum_mb <= 800 or not maximum_mb <= budget_mb <= 10_240:
        raise ValueError('Use 1-30 explicit baseline inspections and at most 10 GiB per batch.')
    probe = lab.validated_campaign_probe(root, probe)
    pairs = lab.load(root / 'external-appcasts/discovered.json')['unverifiedPairs']
    known_repositories = set()
    for cask in lab.load(root / 'homebrew-casks.json'):
        url = urllib.parse.urlsplit(cask.get('url') or '')
        parts = url.path.strip('/').split('/')
        if url.hostname == 'github.com' and len(parts) >= 2:
            known_repositories.add('/'.join(parts[:2]).lower())
    pairs.sort(key=lambda pair: pair['sourceRepository'].lower() in known_repositories)
    review_holds = lab.load(root / 'external-product-review-held.json') if (root / 'external-product-review-held.json').exists() else []
    held_repositories = {item['sourceRepository'].lower() for item in review_holds}
    prior = {lab.load(p).get('discoveryToken') for p in (root / 'external-baselines').glob('*/result.json')}
    verified = {x['bundleID'] for x in lab.load(root / 'report.json')['latestCases'] if lab.upgrade_passed(x)}
    remaining, attempted = budget_mb * 1024**2, 0
    for pair in pairs:
        token = pair['token']
        if token in prior or pair['sourceRepository'].lower() in held_repositories or not re.fullmatch(r'external-[a-f0-9]{40}', token):
            continue
        if attempted >= limit or remaining < maximum_mb * 1024**2:
            break
        if shutil.disk_usage(root).free < 20 * 1024**3:
            raise ValueError('Keep at least 20 GiB free before another baseline.')
        case = lab.private_root(root / 'external-baselines' / (token + '-' + uuid.uuid4().hex[:12]))
        (case / 'explicit-acceptance-root').write_text(str(case))
        lab.write_json(case / 'input.json', pair | {'startedAt': lab.now(), 'probeSHA256': lab.sha256(probe)})
        archive = case / 'old.archive'
        charged = maximum_mb * 1024**2
        attempted += 1
        print('Inspecting external baseline', pair['sourceRepository'], flush=True)
        try:
            lab.download(pair['oldURL'], archive, charged, proxy_port)
            charged = archive.stat().st_size
            command = [str(probe), 'external-baseline', '--catalog', str(root / 'homebrew-casks.json'), '--root', str(case),
                       '--old-archive', str(archive), '--old-url', pair['oldURL'], '--old-ed-signature', pair['oldEDSignature']]
            with (case / 'probe.log').open('w') as log:
                result = subprocess.run(command, env=dict(os.environ, UPOVI_LOG_DIRECTORY=str(case / 'Logs')), stdout=log, stderr=subprocess.STDOUT)
            if not (case / 'result.json').exists():
                raise RuntimeError('Baseline inspector did not produce terminal evidence.')
            evidence = lab.load(case / 'result.json')
            evidence.update(discoveryToken=token, probeExitCode=result.returncode, probeSHA256=lab.sha256(probe),
                            sourceRepository=pair['sourceRepository'], productReviewRequired=True, upgradeVerified=False)
            evidence['alreadyCountedApplication'] = evidence.get('bundleID') in verified
            keep = evidence.get('baselineInspected') is True and evidence.get('oldSignatureVerified') is True and evidence.get('oldEnclosureSignatureVerified') is True and evidence.get('temporaryCopiesRemoved') is True and not evidence['alreadyCountedApplication']
            evidence['archiveRetainedForReview'] = keep
            recovery = evidence.get('temporaryCopiesRemoved') is not True
            evidence['archiveRetainedForRecovery'] = recovery
            if not keep and not recovery:
                archive.unlink(missing_ok=True)
            lab.write_json(case / 'result.json', evidence)
            print('Baseline identity', evidence.get('bundleID', 'unavailable'), 'review required:', keep, 'upgradeVerified=false', flush=True)
        except (subprocess.CalledProcessError, ValueError, RuntimeError) as error:
            archive.unlink(missing_ok=True)
            lab.write_json(case / 'result.json', {'discoveryToken': token, 'testedAt': lab.now(), 'stage': 'baselineDownloadOrProbe',
                'sourceRepository': pair['sourceRepository'], 'oldSourceURL': pair['oldURL'],
                'upgradeVerified': False, 'baselineInspected': False, 'productReviewRequired': True, 'errorType': type(error).__name__,
                **lab.archive_failure(error), 'terminal': True})
        finally:
            remaining -= charged
    print({'inspectedBaselines': attempted, 'verifiedApps': 0, 'retainedArchivesRequireProductReview': True})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare')
    baseline = commands.add_parser('inspect')
    baseline.add_argument('--probe', type=pathlib.Path, required=True)
    baseline.add_argument('--limit', type=int, required=True)
    baseline.add_argument('--budget-mb', type=int, required=True)
    baseline.add_argument('--max-old-mb', type=int, default=300)
    baseline.add_argument('--proxy-port', type=int)
    options = parser.parse_args()
    root = lab.private_root(options.root)
    if options.command == 'prepare':
        prepare(root)
    else:
        inspect(root, options.probe, options.limit, options.budget_mb, options.max_old_mb, options.proxy_port)


if __name__ == '__main__':
    main()
