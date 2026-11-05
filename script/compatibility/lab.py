#!/usr/bin/env python3
"""Explicit, local-only compatibility inventory and isolated upgrade acceptance.

Metadata candidates never count as verified upgrades. No app is launched, no PKG
is executed, and no daily-use /Applications bundle is passed to the installer.
"""
import argparse
import collections
import contextlib
import datetime as dt
import hashlib
import fcntl
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.parse
import uuid

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
CATALOG_URL = 'https://formulae.brew.sh/api/cask.json'
POPULARITY_URL = 'https://formulae.brew.sh/api/analytics/cask-install/365d.json'


class DownloadBudgetExceeded(ValueError):
    failure_class = 'packageByteBudget'


class ArchiveIntegrityMismatch(ValueError):
    failure_class = 'archiveIntegrityRejected'


def archive_failure(error):
    code = getattr(error, 'returncode', None)
    return {'failureClass': getattr(error, 'failure_class', None) or {
        22: 'httpRejected', 28: 'networkTimeout', 60: 'tlsRejected', 5: 'proxyUnavailable', 6: 'hostUnavailable',
        7: 'connectionUnavailable', 63: 'packageByteBudget'}.get(code, 'downloadOrProbe'), 'transportExitCode': code}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def private_root(path):
    path = pathlib.Path(os.path.abspath(path))
    if path != path.resolve() or not path.is_relative_to(REPOSITORY / '.local') or path == REPOSITORY / '.local':
        raise ValueError('Use an unlinked directory strictly below repository .local.')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def write_json(path, value):
    temporary = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    with temporary.open('x') as file:
        os.chmod(temporary, 0o600)
        json.dump(value, file, indent=2, sort_keys=True)
        file.write('\n')
    temporary.replace(path)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def https_url(value):
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError('Use a public HTTPS URL without credentials or fragments.')
    return value


def download(url, destination, maximum, proxy_port=None):
    https_url(url)
    partial = destination.with_suffix('.partial')
    command = ['curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
               '--proto-redir', '=https', '--connect-timeout', '20', '--max-time', '240',
               '--max-filesize', str(maximum), '--output', str(partial)]
    if proxy_port:
        command += ['--proxy', f'http://127.0.0.1:{proxy_port}']
    try:
        completed = subprocess.run(command + [url], capture_output=True, text=True)
        if completed.returncode and 'Maximum file size exceeded' in completed.stderr:
            raise DownloadBudgetExceeded('Package exceeds the explicit byte budget.')
        completed.check_returncode()
        if partial.stat().st_size > maximum:
            raise ValueError('Download byte budget exceeded.')
        partial.chmod(0o600)
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def load(path):
    return json.loads(path.read_text())


def validated_campaign_probe(root, probe):
    probe = pathlib.Path(probe).absolute()
    if probe != probe.resolve() or not probe.is_relative_to(root / 'builds') or not probe.is_file():
        raise ValueError('Select an immutable unlinked probe under this lab root builds directory.')
    manifest = probe.parent / 'build-manifest.json'
    if manifest.resolve() != manifest or not manifest.is_file() or load(manifest).get('binarySHA256') != sha256(probe):
        raise ValueError('Selected probe does not match its build provenance.')
    return probe


def campaign_probe(root, requested, pinned=False):
    """Apply only an explicitly selected local policy to future batch invocations.

    Running cases keep their immutable binary. Requested/effective hashes remain
    separate; a changed binary never reuses an older binary's resume success.
    """
    details = {'requestedProbeSHA256': sha256(requested)}
    policy_path = root / 'campaign-probe-selection.json'
    if pinned or not policy_path.exists():
        return requested, details
    if policy_path.resolve() != policy_path or policy_path.stat().st_size > 16_384:
        raise ValueError('Invalid local campaign probe policy.')
    policy = load(policy_path)
    if policy.get('schemaVersion') != 1:
        raise ValueError('Unsupported local campaign probe policy.')
    if details['requestedProbeSHA256'] not in policy.get('replaceRequestedProbeSHA256', []):
        return requested, details
    selected = validated_campaign_probe(root, root / policy['effectiveProbe'])
    if sha256(selected) != policy['effectiveProbeSHA256']:
        raise ValueError('Campaign probe policy hash mismatch.')
    details['probeSelectionPolicySHA256'] = sha256(policy_path)
    print('Using explicitly selected campaign probe:', policy['effectiveProbeSHA256'],
          'requested:', details['requestedProbeSHA256'], flush=True)
    return selected, details


def reviewed_external_baseline(root, entry, probe):
    """An inspected old bundle is not product approval or an upgrade acceptance."""
    review = entry.get('externalReview', {})
    if review.get('schemaVersion') != 1 or review.get('productReviewed') is not True or not review.get('productPurpose'):
        raise ValueError('External application requires an explicit primary product review.')
    https_url(review['primaryProductURL'])
    expected = {'bundleID': entry['bundleID'], 'oldVersion': entry['oldVersion'],
                'oldTeamID': review['teamID'], 'application': review['application'], 'oldSourceURL': entry['oldURL']}
    if review.get('bundleID') != entry['bundleID'] or not re.fullmatch(r'[A-Z0-9]{10}', review['teamID']):
        raise ValueError('External product review identity mismatch.')
    evidence_file = root / review['baselineEvidence']
    if evidence_file.resolve() != evidence_file or not evidence_file.is_relative_to(root / 'external-baselines') or evidence_file.name != 'result.json':
        raise ValueError('External baseline evidence must remain inside this private lab.')
    evidence = load(evidence_file)
    if any(evidence.get(key) != value for key, value in expected.items()) or any(evidence.get(key) is not True for key in
            ['baselineInspected', 'oldSignatureVerified', 'oldEnclosureSignatureVerified', 'temporaryCopiesRemoved', 'terminal']):
        raise ValueError('External baseline was not fully inspected and signature verified.')
    if evidence.get('bundlePackageType') != 'APPL' or evidence.get('backgroundOnly') is True:
        raise ValueError('External baseline does not establish the reviewed main user application.')
    if evidence.get('oldArchiveSHA256') != entry.get('oldObservedSHA256') or not re.fullmatch(r'[0-9a-f]{64}', entry.get('oldObservedSHA256', '')):
        raise ValueError('External baseline observation mismatch; it is not a published SHA256 proof.')
    source_file = evidence_file.parent / 'input.json'
    if source_file.resolve() != source_file:
        raise ValueError('External baseline source evidence is linked.')
    source = load(source_file)
    if source.get('oldURL') != entry['oldURL'] or source.get('oldEDSignature') != entry.get('oldEDSignature'):
        raise ValueError('Reviewed old enclosure no longer matches its immutable feed discovery.')
    manifest = load(probe.parent / 'build-manifest.json')
    if 'externalReviewedBaselineV1' not in manifest.get('capabilities', []) or manifest.get('binarySHA256') != sha256(probe):
        raise ValueError('This probe cannot execute reviewed external baseline acceptance.')
    archive = evidence_file.parent / 'old.archive'
    if archive.exists() and (archive.resolve() != archive or sha256(archive) != entry['oldObservedSHA256']):
        raise ValueError('Reviewed baseline archive cache changed.')
    return archive if archive.exists() else None


@contextlib.contextmanager
def shared_batch(root, manifest, probe, limit):
    """Coordinate explicitly registered batches; dispatch completion is not app success."""
    registry_path = root / 'shared-campaign-batches.json'
    if not registry_path.exists():
        yield True
        return
    if registry_path.resolve() != registry_path or registry_path.stat().st_size > 100_000:
        raise ValueError('Invalid private shared batch registry.')
    registry = load(registry_path)
    manifest = pathlib.Path(manifest).absolute()
    registered = registry.get('manifests', {}).get(manifest.name)
    if registered is None:
        yield True
        return
    if registry.get('schemaVersion') != 1 or manifest.resolve() != manifest or manifest.parent != root or sha256(manifest) != registered:
        raise ValueError('Shared batch no longer matches its explicit immutable registration.')
    if limit != len(load(manifest)):
        raise ValueError('A registered shared batch must process its complete explicit manifest.')
    state = private_root(root / 'shared-batches')
    identity = {'manifestSHA256': registered, 'probeSHA256': sha256(probe), 'catalogSHA256': sha256(root / 'homebrew-casks.json')}
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    marker = state / (key + '.processed.json')
    lock_path = state / (registered + '.lock')
    if lock_path.resolve() != lock_path:
        raise ValueError('Linked shared batch lock.')
    with lock_path.open('a') as lock:
        os.chmod(lock_path, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Shared batch skipped: another live worker owns', manifest.name, flush=True)
            yield False
            return
        try:
            if marker.exists():
                if marker.resolve() != marker or any(load(marker).get(k) != v for k, v in identity.items()):
                    raise ValueError('Shared batch dispatch checkpoint mismatch.')
                print('Shared batch skipped: inputs already processed with this exact probe/catalog;', manifest.name, 'failures remain in the case ledger.', flush=True)
                yield False
                return
            yield True
            write_json(marker, identity | {'manifest': manifest.name, 'finishedAt': now(), 'status': 'inputsProcessed',
                       'meaning': 'Every input was processed or resumed. This is never evidence of any verified app.'})
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def collect(root, catalog=None, popularity=None):
    inputs = []
    prior = {item['file']: item for item in load(root / 'inputs.json')['inputs']} if (root / 'inputs.json').exists() else {}
    for name, source, url in [('homebrew-casks.json', catalog, CATALOG_URL),
                              ('homebrew-popularity-365d.json', popularity, POPULARITY_URL)]:
        destination = root / name
        if source:
            source = pathlib.Path(source).resolve()
            if source != destination:
                shutil.copyfile(source, destination)
        elif not destination.exists():
            download(url, destination, 40_000_000)
        parsed = load(destination)
        if name == 'homebrew-casks.json' and not isinstance(parsed, list):
            raise ValueError('Catalog must be an array.')
        if name != 'homebrew-casks.json' and not isinstance(parsed.get('items'), list):
            raise ValueError('Popularity items must be an array.')
        digest = sha256(destination)
        captured = prior[name]['capturedAt'] if name in prior and prior[name]['sha256'] == digest else now()
        inputs.append({'file': name, 'sourceURL': url, 'sha256': digest,
                       'bytes': destination.stat().st_size,
                       'capturedAt': captured, 'observedAt': now(), 'retrieval': 'caller-supplied snapshot' if source else 'HTTPS download or retained snapshot'})
    write_json(root / 'inputs.json', {'schemaVersion': 1, 'inputs': inputs})


def inventory(rows, popularity, os_major):
    ranks = {}
    for item in popularity['items']:
        token = item['cask'].split()[0]
        count = int(item['count'].replace(',', ''))
        ranks[token] = max(count, ranks.get(token, 0))
    queue = []
    totals = collections.Counter()
    identities = collections.defaultdict(set)
    for row in rows:
        totals['catalogRecords'] += 1
        if row['disabled']:
            totals['disabledRecords'] += 1
            continue
        if '@' in row['token']:
            totals['versionedOrPrereleaseRecords'] += 1
            continue
        app_names = row['declaredAppNames']
        platform = next(p for p in row['platforms'] if p['macOSMajor'] == os_major and p['architecture'] == 'arm64')
        if not app_names and not urllib.parse.urlsplit(platform['url']).path.lower().endswith('.pkg'):
            totals['nonAppOrUndeclaredInstallerRecords'] += 1
            continue
        totals['activeStableAppOrPackageCandidates'] += 1
        if app_names:
            totals['activeStableDirectAppCandidates'] += 1
        if platform['checksumDescriptorAvailable']:
            totals['arm64ChecksumMetadataCandidates'] += 1
        if not row['declaredBundleIDs']:
            totals['candidatesWithoutDeclaredBundleID'] += 1
        for identity in set(row['declaredBundleIDs']):
            identities[identity].add(row['token'])
        queue.append({'token': row['token'], 'annualHomebrewInstalls': ranks.get(row['token'], 0),
                      'declaredAppNames': app_names, 'declaredBundleIDs': sorted(set(row['declaredBundleIDs'])),
                      'arm64ChecksumMetadataAvailable': platform['checksumDescriptorAvailable'],
                      'version': platform['version'], 'nextGate': 'obtain authentic old bundle and inspect actual identity',
                      'upgradeVerified': False})
    queue.sort(key=lambda x: (-x['annualHomebrewInstalls'], x['token']))
    # Declared quit IDs may include helpers; never label this count as verified unique apps.
    totals['declaredQuitIdentifiers'] = len(identities)
    totals['identifiersSharedByMultipleCandidates'] = sum(len(tokens) > 1 for tokens in identities.values())
    totals['payloadVerifiedApps'] = 0
    totals['upgradeVerifiedApps'] = 0
    return dict(totals), queue


def upgrade_passed(result):
    kind = result.get('caseKind', result.get('kind'))
    if kind not in [None, 'externalReviewedAppcast']:
        return False
    if kind == 'externalReviewedAppcast' and not all(result.get(key) is True for key in
            ['externalProductReviewVerified', 'oldEnclosureSignatureVerified']):
        return False
    gates = ['oldSignatureVerified', 'sourceVerified', 'payloadVerified', 'installationPassed',
             'postInstallCurrent', 'restorePassed', 'upgradeVerified', 'temporaryCopiesRemoved']
    return all(result.get(gate) is True for gate in gates) and result.get('stage') == 'complete'


def report(root):
    audit = load(root / 'audit.json')
    popularity = load(root / 'homebrew-popularity-365d.json')
    totals, queue = inventory(audit['rows'], popularity, 27)
    attempts = []
    for file in sorted((root / 'cases').glob('*/result.json')):
        result = load(file)
        result['evidence'] = str(file.relative_to(root))
        input_file = file.parent / 'input.json'
        result['caseToken'] = load(input_file)['token'] if input_file.exists() else result['bundleID']
        # A cleanup verdict is also terminal evidence from the initial probe format.
        result['terminal'] = result.get('terminal', 'temporaryCopiesRemoved' in result)
        attempts.append(result)
    latest = {}
    for result in sorted(attempts, key=lambda r: r.get('testedAt', '')):
        latest[(result['caseToken'], result.get('architecture', 'unknown'), result.get('hostOS', 'unknown'), result.get('releaseChannel', 'stable'))] = result
    passed = [r for r in latest.values() if upgrade_passed(r)]
    inspections = {}
    for file in sorted((root / 'payloads').glob('*/result.json'), key=lambda p: load(p).get('testedAt', '')):
        result = load(file)
        result['evidence'] = str(file.relative_to(root))
        inspections[result['token']] = result
    inspected_ids = {app['bundleID'] for r in inspections.values() if r.get('payloadVerified') is True
                     and r.get('temporaryCopiesRemoved') is True for app in r.get('applications', [])}
    totals['payloadVerifiedApps'] = len(inspected_ids | {r['bundleID'] for r in latest.values() if r.get('payloadVerified') is True})
    totals['upgradeVerifiedApps'] = len({r['bundleID'] for r in passed})
    recent = []
    for result in passed:
        try:
            age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(result['testedAt'].replace('Z', '+00:00'))
            if dt.timedelta(0) <= age <= dt.timedelta(days=7):
                recent.append(result)
        except (KeyError, TypeError, ValueError):
            pass
    totals['upgradeVerifiedAppsWithin7Days'] = len({r['bundleID'] for r in recent})
    totals['payloadInspectionAttempts'] = len(list((root / 'payloads').glob('*/result.json')))
    totals['latestBlockedPayloadInspections'] = sum(r.get('payloadVerified') is not True for r in inspections.values())
    totals['upgradeAttempts'] = len(attempts)
    totals['latestFailedOrBlockedCases'] = sum(r.get('terminal') is True and not upgrade_passed(r) for r in latest.values())
    totals['runningOrInterruptedCases'] = sum(r.get('terminal') is not True for r in latest.values())
    value = {'schemaVersion': 1, 'generatedAt': now(), 'totals': totals,
             'inputProvenance': load(root / 'inputs.json'),
             'popularityWindow': [popularity['start_date'], popularity['end_date']],
             'countingPolicy': 'Catalog/metadata rows are NOT verified upgrades. Latest attempt per case token/OS/architecture/channel; unique verified apps use actual signed bundle IDs. Architectures, channels and repeats do not add apps.',
             'scope': 'macOS 27 metadata matrix; actual host OS/architecture on each upgrade. No first launch, PKG, extensions, licenses or Intel runtime claim.',
             'payloadBlockerClasses': dict(collections.Counter(r.get('failureClass') or r.get('errorKind') or 'unclassified'
                  for r in inspections.values() if r.get('payloadVerified') is not True)),
             'latestCases': list(latest.values()), 'latestPayloadInspections': list(inspections.values()), 'priorityQueue': queue}
    write_json(root / 'report.json', value)
    lines = ['# Compatibility lab', '', f'Generated: {value["generatedAt"]}', '',
             'Metadata candidates are not verified upgrades. Popularity is a Homebrew-install proxy.', '',
             '| Metric | Count |', '| --- | ---: |']
    lines += [f'| {key} | {count} |' for key, count in totals.items()]
    lines += ['', '## Actual upgrade cases', '', '| Bundle | Channel | From | Selected | Stage | Upgrade + restore |', '| --- | --- | --- | --- | --- | --- |']
    lines += [f'| {r["bundleID"]} | {r.get("releaseChannel", "stable")} | {r.get("fromVersion", "")} | {r.get("selectedVersion", "")} | {r.get("stage", "")} | {"PASS" if upgrade_passed(r) else "BLOCKED / FAIL"} |' for r in latest.values()]
    lines += ['', 'A pass covers production source selection, verified payload, isolated replacement, post-install check and restoration on the recorded host. It does not claim first-launch or privileged-install acceptance.', '',
              '## Priority cohort', '', '| Cask | Annual installs | Checksum metadata |', '| --- | ---: | --- |']
    lines += [f'| {r["token"]} | {r["annualHomebrewInstalls"]} | {r["arm64ChecksumMetadataAvailable"]} |' for r in queue[:100]]
    (root / 'report.md').write_text('\n'.join(lines) + '\n')
    print(json.dumps(totals, indent=2))


def inspect_payloads(root, probe, limit, budget_mb, maximum_mb, tokens, proxy_port):
    if not 1 <= limit <= 100 or not 1 <= maximum_mb <= 1024 or not maximum_mb <= budget_mb <= 20_480:
        raise ValueError('Explicit inspections: 1-100 cases, 1-1024 MiB per package, up to 20 GiB per batch.')
    audit = load(root / 'audit.json')
    popularity = load(root / 'homebrew-popularity-365d.json')
    _, queue = inventory(audit['rows'], popularity, 27)
    by_token = {r['token']: r for r in audit['rows']}
    remaining = budget_mb * 1024**2
    attempted = 0
    for item in queue:
        if tokens and item['token'] not in tokens:
            continue
        if not item['declaredAppNames'] or not item['arm64ChecksumMetadataAvailable']:
            continue
        if not tokens and item['declaredBundleIDs']:
            continue
        if remaining < maximum_mb * 1024**2 or attempted >= limit:
            break
        if shutil.disk_usage(root).free < 20 * 1024**3:
            raise ValueError('Keep at least 20 GiB free before starting another payload.')
        platform = next(p for p in by_token[item['token']]['platforms'] if p['architecture'] == 'arm64' and p['macOSMajor'] == 27)
        case = private_root(root / 'payloads' / (item['token'] + '-' + uuid.uuid4().hex[:12]))
        (case / 'explicit-acceptance-root').write_text(str(case))
        write_json(case / 'input.json', {'token': item['token'], 'sourceURL': platform['url'], 'sourceSHA256': platform['sha256'], 'startedAt': now()})
        archive = case / 'payload.archive'
        attempted += 1
        charged = maximum_mb * 1024**2
        print('Inspecting', item['token'], flush=True)
        try:
            download(platform['url'], archive, charged, proxy_port)
            charged = archive.stat().st_size
            if sha256(archive) != platform['sha256']:
                raise ValueError('Source checksum mismatch.')
            probe_hash = sha256(probe)
            with (case / 'probe.log').open('w') as log:
                completed = subprocess.run([str(probe), 'payload', '--catalog', str(root / 'homebrew-casks.json'),
                    '--root', str(case), '--archive', str(archive), '--cask', item['token']],
                    env=dict(os.environ, UPOVI_LOG_DIRECTORY=str(case / 'Logs')), stdout=log, stderr=subprocess.STDOUT)
            if not (case / 'result.json').exists():
                raise RuntimeError('Probe did not produce terminal evidence; inspect private probe.log.')
            result = load(case / 'result.json')
            result.update(probeExitCode=completed.returncode, probeSHA256=probe_hash)
            write_json(case / 'result.json', result)
            print(item['token'], 'PAYLOAD PASS' if result.get('payloadVerified') is True else 'BLOCKED / FAIL', flush=True)
        except (subprocess.CalledProcessError, ValueError, RuntimeError) as error:
            if not (case / 'result.json').exists():
                write_json(case / 'result.json', {'token': item['token'], 'testedAt': now(), 'stage': 'downloadOrProbe',
                           'payloadVerified': False, 'upgradeVerified': False, 'errorType': type(error).__name__, 'terminal': True,
                           'failureClass': getattr(error, 'failure_class', None) or {63: 'packageByteBudget', 22: 'httpRejected', 28: 'networkTimeout',
                                            60: 'tlsRejected', 5: 'proxyUnavailable'}.get(getattr(error, 'returncode', None), 'downloadOrProbe'),
                           'transportExitCode': getattr(error, 'returncode', None)})
            print(item['token'], type(error).__name__, flush=True)
        finally:
            archive.unlink(missing_ok=True)
            # Failed transfers reserve the full per-package cap, conservatively bounding this explicit batch.
            remaining -= charged
            report(root)


def export_evidence(root, destination):
    report_value = load(root / 'report.json')
    keep = {'bundleID', 'caseToken', 'fromVersion', 'oldBuild', 'oldTeamID', 'oldSignatureVerified', 'oldArchiveSHA256', 'selectedVersion',
            'selectedBuild', 'selectedSource', 'sourceStatus', 'sourceVerified', 'checkedSources', 'installedVersion',
            'installedBuild', 'newTeamID', 'stage', 'errorKind', 'hostOS', 'architecture', 'testedAt', 'payloadVerified',
            'archiveIntegrityVerified', 'installationPassed', 'postInstallCurrent', 'restorePassed', 'upgradeVerified',
            'temporaryCopiesRemoved', 'firstLaunchTested', 'systemComponentsTested', 'probeSHA256', 'sourceSHA256', 'sourceSHA512', 'sourceChecks',
            'oldArchiveExpectedSHA256', 'oldReleaseURL', 'releaseChannel', 'selectedReleaseChannel', 'selectedIsPrerelease', 'selectedStablePackagingReviewed',
            'requestedProbeSHA256', 'probeSelectionPolicySHA256', 'caseKind', 'externalProductReviewVerified',
            'externalReviewSHA256', 'oldEnclosureSignatureVerified', 'oldObservedSHA256', 'primaryProductURL',
            'failureClass', 'transportExitCode'}
    cases = [{k: v for k, v in r.items() if k in keep} for r in report_value['latestCases']]
    payload_keys = {'token', 'testedAt', 'hostOS', 'architecture', 'sourceURL', 'sourceSHA256', 'observedSHA256', 'stage', 'payloadVerified',
                    'upgradeVerified', 'firstLaunchTested', 'systemComponentsTested', 'mappingReviewRequired',
                    'applications', 'temporaryCopiesRemoved', 'errorKind', 'errorType', 'failureClass', 'transportExitCode', 'probeSHA256'}
    inspections = [{k: v for k, v in r.items() if k in payload_keys} for r in report_value['latestPayloadInspections']]
    value = {k: report_value[k] for k in ['schemaVersion', 'generatedAt', 'totals', 'inputProvenance', 'popularityWindow', 'countingPolicy', 'scope', 'payloadBlockerClasses']}
    value.update(latestCases=cases, latestPayloadInspections=inspections,
                 testedGitHead=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPOSITORY, text=True).strip(),
                 firstCohortManifestSHA256=sha256(REPOSITORY / 'script/compatibility/first-cohort.json'),
                 workingTreeWasModified=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=REPOSITORY)))
    probe_hashes = {r.get('probeSHA256') for r in cases + inspections}
    manifests = list((root / 'bin/build-manifests').glob('*.json')) + list((root / 'builds').glob('*/build-manifests/*.json'))
    value['probeBuilds'] = [load(file) for file in manifests
                            if file.stem in probe_hashes]
    validation = {}
    for name in ['swift-tests.log', 'app-tests.log', 'python-tests.log', 'reviewed-catalog-live.log']:
        file = root / name
        if not file.exists():
            continue
        log = file.read_text(errors='replace')
        match = re.findall(r'Executed (\d+) tests, with 0 failures', log)
        full_suite = "Test Suite 'All tests' passed" in log
        core_suite = name == 'swift-tests.log' and "Test Suite 'UpoviCoreTests.xctest' passed" in log and "Test Suite 'Selected tests' passed" in log
        if match and (full_suite or core_suite) and (name != 'app-tests.log' or '** TEST SUCCEEDED **' in log):
            validation[name] = {'passedTests': int(match[-1]), 'logSHA256': sha256(file),
                                'scope': 'UpoviCoreTests' if core_suite else 'hosted UpoviTests' if name == 'app-tests.log' else 'all tests'}
        elif name == 'python-tests.log' and '\nOK\n' in log:
            count = re.search(r'Ran (\d+) tests', log)
            if count:
                validation[name] = {'passedTests': int(count[1]), 'logSHA256': sha256(file)}
        elif name == 'reviewed-catalog-live.log':
            count = re.search(r'(\d+) reviewed identities validated', log)
            if count:
                validation[name] = {'reviewedIdentities': int(count[1]), 'logSHA256': sha256(file)}
    value['validationReports'] = validation
    write_json(destination, value)


def resumable_success(root, entry, catalog_hash, probe_hash):
    """Only reuse recent full passes for identical inputs and the identical probe binary."""
    files = sorted((root / 'cases').glob(entry['token'] + '-*/input.json'), key=lambda p: load(p).get('startedAt', ''), reverse=True)
    for file in files:
        prior = load(file)
        if any(prior.get(key) != entry.get(key) for key in ['bundleID', 'oldVersion', 'oldURL', 'oldSHA256', 'discoverBaseline', 'cask',
                                                        'kind', 'oldObservedSHA256', 'oldEDSignature', 'externalReview']):
            continue
        if prior.get('releaseChannel', 'stable') != entry.get('releaseChannel', 'stable'):
            continue
        if prior.get('catalogSHA256') != catalog_hash or prior.get('probeSHA256') != probe_hash:
            continue
        result_file = file.parent / 'result.json'
        if not result_file.exists() or not upgrade_passed(load(result_file)):
            return False
        if entry.get('kind') == 'externalReviewedAppcast' and load(result_file).get('caseKind') != 'externalReviewedAppcast':
            return False
        age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(prior['startedAt'])
        if dt.timedelta(0) <= age <= dt.timedelta(days=7):
            return True
        return False
    return False


def run_cases(root, manifest, probe, limit, proxy_port, max_old_mb, resume=False, selection=None):
    entries = load(manifest)
    if not isinstance(entries, list) or not 1 <= limit <= 50:
        raise ValueError('Explicit batches accept between 1 and 50 cases.')
    attempted = 0
    for entry in entries:
        if attempted >= limit:
            break
        if not re.fullmatch(r'[a-z0-9][a-z0-9+_-]{0,100}', entry['token']):
            raise ValueError('Invalid case token.')
        https_url(entry['oldURL'])
        if entry.get('kind') not in [None, 'externalReviewedAppcast']:
            raise ValueError('Research feed pairs require signed baseline inspection and product review before installation.')
        if entry.get('releaseChannel', 'stable') not in ['stable', 'beta']:
            raise ValueError('Use stable or beta as the explicit case channel.')
        probe_hash = sha256(probe)
        external = entry.get('kind') == 'externalReviewedAppcast'
        baseline_archive = reviewed_external_baseline(root, entry, probe) if external else None
        catalog_hash = sha256(root / 'homebrew-casks.json')
        if resume and resumable_success(root, entry, catalog_hash, probe_hash):
            print('Resuming after recent identical-input pass:', entry['token'], flush=True)
            continue
        if shutil.disk_usage(root).free < 20 * 1024**3:
            raise ValueError('Keep at least 20 GiB free before starting another case.')
        case = private_root(root / 'cases' / (entry['token'] + '-' + uuid.uuid4().hex[:12]))
        (case / 'explicit-acceptance-root').write_text(str(case))
        attempted += 1
        write_json(case / 'input.json', {**entry, **(selection or {}), 'startedAt': now(), 'catalogSHA256': catalog_hash, 'probeSHA256': probe_hash})
        archive = case / 'old.archive'
        observed_old_sha = None
        print('Starting', entry['token'], flush=True)
        try:
            if baseline_archive:
                if baseline_archive.stat().st_size > max_old_mb * 1024**2:
                    raise ValueError('Reviewed old archive exceeds the explicit case budget.')
                shutil.copyfile(baseline_archive, archive)
            else:
                download(entry['oldURL'], archive, max_old_mb * 1024**2, proxy_port)
            observed_old_sha = sha256(archive)
            if entry.get('oldSHA256') and observed_old_sha != entry['oldSHA256']:
                raise ArchiveIntegrityMismatch('Old archive independent checksum mismatch.')
            if external and observed_old_sha != entry['oldObservedSHA256']:
                raise ArchiveIntegrityMismatch('Reviewed old archive differs from the observed baseline.')
            environment = dict(os.environ, UPOVI_LOG_DIRECTORY=str(case / 'Logs'))
            command = [str(probe), 'upgrade', '--catalog', str(root / 'homebrew-casks.json'), '--root', str(case),
                       '--old-archive', str(archive), '--bundle-id', entry['bundleID'], '--old-version', entry['oldVersion']]
            if proxy_port:
                command += ['--proxy-port', str(proxy_port)]
            if entry.get('discoverBaseline') is True:
                command += ['--discover-baseline', '--cask', entry['cask']]
            command += ['--channel', entry.get('releaseChannel', 'stable')]
            if external:
                command += ['--old-ed-signature', entry['oldEDSignature'], '--old-url', entry['oldURL'],
                            '--reviewed-team-id', entry['externalReview']['teamID'], '--reviewed-application', entry['externalReview']['application']]
            with (case / 'probe.log').open('w') as log:
                completed = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
            if not (case / 'result.json').exists():
                raise RuntimeError(f'Probe exited {completed.returncode} without terminal evidence; inspect private probe.log.')
            result = load(case / 'result.json')
            result.update(terminal=True, probeExitCode=completed.returncode, probeSHA256=probe_hash, caseToken=entry['token'])
            result.update(selection or {})
            if external:
                result.update(caseKind='externalReviewedAppcast', externalProductReviewVerified=True,
                    externalReviewSHA256=hashlib.sha256(json.dumps(entry['externalReview'], sort_keys=True).encode()).hexdigest(),
                    oldObservedSHA256=entry['oldObservedSHA256'], primaryProductURL=entry['externalReview']['primaryProductURL'])
                if result.get('oldEnclosureSignatureVerified') is not True:
                    result['upgradeVerified'] = False
            if entry.get('oldSHA256'):
                result['oldArchiveExpectedSHA256'] = entry['oldSHA256']
            if entry.get('oldReleaseURL'):
                result['oldReleaseURL'] = entry['oldReleaseURL']
            write_json(case / 'result.json', result)
            print(entry['token'], 'PASS' if upgrade_passed(load(case / 'result.json')) else 'BLOCKED / FAIL', flush=True)
        except (subprocess.CalledProcessError, ValueError, RuntimeError) as error:
            if not (case / 'result.json').exists():
                write_json(case / 'result.json', {'bundleID': entry['bundleID'], 'fromVersion': entry['oldVersion'],
                           'testedAt': now(), 'stage': 'oldArchiveDownloadOrProbe', 'upgradeVerified': False, 'terminal': True,
                           'errorType': type(error).__name__, **archive_failure(error),
                           'oldArchiveSHA256': observed_old_sha, 'oldArchiveExpectedSHA256': entry.get('oldSHA256'),
                           'oldReleaseURL': entry.get('oldReleaseURL')})
            print(entry['token'], type(error).__name__, flush=True)
        finally:
            archive.unlink(missing_ok=True)
            report(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--probe', type=pathlib.Path, help='Use an immutable separately built probe under repository .local.')
    parser.add_argument('--pin-probe', action='store_true', help='Reproduce the requested binary exactly, ignoring an explicit local campaign selection.')
    subs = parser.add_subparsers(dest='command', required=True)
    collect_parser = subs.add_parser('collect')
    collect_parser.add_argument('--catalog', type=pathlib.Path)
    collect_parser.add_argument('--popularity', type=pathlib.Path)
    subs.add_parser('build')
    subs.add_parser('audit')
    subs.add_parser('report')
    selection = subs.add_parser('select-probe', help='Explicitly select a proven immutable probe for future campaign batches.')
    selection.add_argument('--replace-probe', type=pathlib.Path, action='append', required=True)
    export = subs.add_parser('export')
    export.add_argument('--output', type=pathlib.Path, required=True)
    inspect = subs.add_parser('inspect')
    inspect.add_argument('--limit', type=int, required=True)
    inspect.add_argument('--budget-mb', type=int, required=True)
    inspect.add_argument('--max-package-mb', type=int, default=100)
    inspect.add_argument('--token', action='append', default=[])
    inspect.add_argument('--proxy-port', type=int, choices=range(1, 65536), metavar='PORT')
    run = subs.add_parser('run')
    run.add_argument('--manifest', type=pathlib.Path, required=True)
    run.add_argument('--limit', type=int, required=True)
    run.add_argument('--proxy-port', type=int, choices=range(1, 65536), metavar='PORT')
    run.add_argument('--max-old-mb', type=int, default=300)
    run.add_argument('--resume', action='store_true', help='Skip recent full passes only for identical catalog, old inputs and probe binary.')
    options = parser.parse_args()
    root = private_root(options.root)
    probe = options.probe.absolute() if options.probe else root / 'bin/compatibility-probe'
    if probe != probe.resolve() or not probe.is_relative_to(REPOSITORY / '.local'):
        parser.error('Use an unlinked probe under repository .local.')
    if options.command == 'collect':
        collect(root, options.catalog, options.popularity)
    elif options.command == 'build':
        from build_probe import build
        build(root / 'bin')
    elif options.command == 'audit':
        subprocess.run([str(probe), 'audit', '--catalog', str(root / 'homebrew-casks.json'), '--output', str(root / 'audit.json')], check=True)
        report(root)
    elif options.command == 'report':
        report(root)
    elif options.command == 'select-probe':
        selected = validated_campaign_probe(root, probe)
        replacements = []
        for requested in options.replace_probe:
            requested = requested.absolute()
            if requested.resolve() != requested or not requested.is_relative_to(root) or not requested.is_file():
                parser.error('Replace only immutable requested probes within this lab root.')
            replacements.append(sha256(requested))
        if not 1 <= len(replacements) <= 32:
            parser.error('Select between 1 and 32 explicit requested probes.')
        write_json(root / 'campaign-probe-selection.json', {'schemaVersion': 1, 'selectedAt': now(),
            'effectiveProbe': str(selected.relative_to(root)), 'effectiveProbeSHA256': sha256(selected),
            'replaceRequestedProbeSHA256': sorted(set(replacements))})
        print('Selected immutable probe for future batch starts; existing processes continue unchanged.')
    elif options.command == 'export':
        export_evidence(root, options.output)
    elif options.command == 'inspect':
        if sys.platform != 'darwin' or os.uname().machine != 'arm64':
            parser.error('The initial payload queue currently targets an Apple silicon macOS host only.')
        inspect_payloads(root, probe, options.limit, options.budget_mb, options.max_package_mb, set(options.token), options.proxy_port)
    else:
        if not 1 <= options.max_old_mb <= 1024:
            parser.error('Old-archive budget must be between 1 and 1024 MiB.')
        probe, selection = campaign_probe(root, probe, options.pin_probe)
        with shared_batch(root, options.manifest, probe, options.limit) as acquired:
            if acquired:
                run_cases(root, options.manifest, probe, options.limit, options.proxy_port, options.max_old_mb, options.resume, selection)


if __name__ == '__main__':
    main()
