#!/usr/bin/env python3
"""Observe an already configured native Upovi process; never changes settings or prevents sleep."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import time


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def run(command, timeout=20):
    return subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=True).stdout


def save(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as handle:
        json.dump(value, handle, indent=2)
        handle.write('\n')
    temporary.chmod(0o600)
    os.replace(temporary, path)


def main():
    def stop_observer(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop_observer)
    signal.signal(signal.SIGINT, stop_observer)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--probe', type=pathlib.Path, required=True)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--expected-scope-count', type=int, default=1)
    parser.add_argument('--duration-seconds', type=int, default=86400)
    parser.add_argument('--interval-seconds', type=int, default=60)
    options = parser.parse_args()
    if not 10 <= options.interval_seconds <= 3600 or not 1 <= options.duration_seconds <= 86400:
        parser.error('Use a 10–3600 second interval and at most 86400 seconds.')
    options.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    pid = str(options.pid)
    identity = run(['ps', '-p', pid, '-o', 'lstart=']).strip()
    process_path = run(['ps', '-p', pid, '-o', 'comm=']).strip()
    if pathlib.Path(process_path).resolve() != (options.app / 'Contents/MacOS/Upovi').resolve():
        raise RuntimeError('PID does not belong to the specified Upovi bundle')
    info = plistlib.loads((options.app / 'Contents/Info.plist').read_bytes())
    started = time.time()
    summary = {'status': 'running', 'startedAt': utc(), 'requestedDurationSeconds': options.duration_seconds,
               'sourceRevision': info.get('UpoviSourceRevision'), 'version': info.get('CFBundleShortVersionString'),
               'binarySHA256': hashlib.sha256((options.app / 'Contents/MacOS/Upovi').read_bytes()).hexdigest(),
               'processID': options.pid, 'expectedScopeCount': options.expected_scope_count, 'samples': 0, 'uiErrors': 0, 'coverageGapsSeconds': [],
               'observedSyncTimes': [], 'rssKBMin': None, 'rssKBMax': None,
               'boundary': 'Real elapsed observation; gaps, exit, source checks and DHT failures require review. CPU/RSS are not direct energy measurements.'}
    save(options.output / 'summary.json', summary)
    children = []
    handles = []
    for name, command in [
        ('traffic.csv', ['nettop', '-P', '-d', '-L', '0', '-s', str(options.interval_seconds), '-p', pid, '-J', 'bytes_in,bytes_out']),
        ('runtime.log', ['/usr/bin/log', 'stream', '--style', 'compact', '--level', 'info', '--predicate',
                         'processIdentifier == '+pid+' AND subsystem == "app.upovi.Upovi"'])]:
        handle = (options.output / name).open('w'); handles.append(handle)
        children.append(subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT))
    previous = started
    next_sample = started
    try:
        while True:
            now = time.time()
            if now < next_sample:
                time.sleep(min(next_sample - now, 30)); continue
            gap = now - previous
            if gap > max(options.interval_seconds * 2, 120):
                summary['coverageGapsSeconds'].append(round(gap, 2))
            sample = {'at': utc(), 'elapsedSeconds': round(now - started, 2)}
            try:
                if run(['ps', '-p', pid, '-o', 'lstart=']).strip() != identity:
                    raise RuntimeError('Process identity changed')
                fields = run(['ps', '-p', pid, '-o', 'rss=,%cpu=,time=']).split()
                sample.update(rssKB=int(fields[0]), cpuPercent=float(fields[1]), cpuTime=fields[2])
            except (subprocess.SubprocessError, ValueError, RuntimeError):
                summary['status'] = 'process_exited_or_changed'; break
            try:
                before = time.monotonic()
                nodes = json.loads(run([str(options.probe.resolve()), '--pid', pid, '--action', 'snapshot']))
                sample['uiProbeSeconds'] = round(time.monotonic() - before, 3)
                texts = [node['value'] for node in nodes if node['role'] == 'AXStaticText']
                sample['syncTimes'] = [text for text in texts if text.startswith('最近发现：')]
                sample['networkStatus'] = [text for text in texts if text.startswith('DHT 响应 ') or text.startswith('正在自动发现')]
                sample['scope'] = [text for text in texts if text.startswith('范围：')]
                sample['visibleCheckHistory'] = [text for text in texts if re.fullmatch(r'\d+ 个应用 · \d+ 个更新 · \d+ 项未完整检查', text)]
                sample['sharingControls'] = [node['value'] for node in nodes if node['role'] == 'AXCheckBox' and node['description'] == '公开共享选中应用的版本']
                sample['visibleWindows'] = len([node for node in nodes if node['role'] == 'AXWindow'])
                for value in sample['syncTimes']:
                    if value not in summary['observedSyncTimes']: summary['observedSyncTimes'].append(value)
                if sample['scope'] and any(value != '范围：'+str(options.expected_scope_count)+' 个应用' for value in sample['scope']):
                    summary['status'] = 'scope_configuration_changed'; summary['failureSample'] = sample; break
                if any(value != '0' for value in sample['sharingControls']):
                    summary['status'] = 'sharing_configuration_changed'; break
            except (subprocess.SubprocessError, ValueError, KeyError):
                sample['uiProbeFailed'] = True; summary['uiErrors'] += 1
            summary['samples'] += 1
            summary['rssKBMin'] = min(summary['rssKBMin'] or sample['rssKB'], sample['rssKB'])
            summary['rssKBMax'] = max(summary['rssKBMax'] or sample['rssKB'], sample['rssKB'])
            summary['elapsedSeconds'] = sample['elapsedSeconds']; summary['lastSampleAt'] = sample['at']
            summary['collectorExitCodes'] = [child.poll() for child in children]
            with (options.output / 'samples.jsonl').open('a') as handle: handle.write(json.dumps(sample) + '\n')
            save(options.output / 'summary.json', summary)
            if now - started >= options.duration_seconds:
                summary['status'] = 'completed_observation_requires_review'; break
            previous = now
            next_sample = min(started + options.duration_seconds, next_sample + options.interval_seconds)
    except BaseException:
        summary['status'] = 'observer_interrupted'; raise
    finally:
        for child in children:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
        for handle in handles: handle.close()
        summary['finishedAt'] = utc(); summary['elapsedSeconds'] = round(time.time() - started, 2)
        save(options.output / 'summary.json', summary)
        print(json.dumps(summary))


if __name__ == '__main__':
    main()
