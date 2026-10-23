#!/usr/bin/env python3
"""Explicit public DHT discovery smoke test. Only synthetic metadata is shared."""
import datetime
import json
import pathlib
import select
import subprocess
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    subprocess.run(['swift', 'build', '--product', 'UpoviPeer'], cwd=ROOT, check=True)
    binary = str(pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()) / 'UpoviPeer')
    evidence = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'network': 'public BitTorrent DHT',
                'reader_had_invitation_or_publisher_key': False, 'cross_network_two_mac_validation': False}
    with tempfile.TemporaryDirectory(prefix='upovi-public-auto-') as directory:
        key = str(pathlib.Path(directory) / 'identity.json')
        subprocess.run([binary, 'identity', '--output', key], check=True, capture_output=True)
        bundle = 'app.upovi.synthetic-discovery.' + uuid.uuid4().hex[:12]
        publisher = subprocess.Popen([binary, 'share-public', '--identity', key, '--bundle', bundle,
                                      '--version', '2.5.0', '--duration', '300'], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            ready, _, _ = select.select([publisher.stdout], [], [], 100)
            if not ready:
                raise RuntimeError('Timed out waiting for public peer announcement')
            line = publisher.stdout.readline().strip()
            if not line.startswith('public_announcements='):
                raise RuntimeError(line + (publisher.stderr.read() if publisher.poll() is not None else ''))
            evidence['publication'] = line
            print(line, flush=True)
            for attempt in range(3):
                reader = subprocess.run([binary, 'discover', '--bundle', bundle, '--version', '1.0'],
                                        text=True, capture_output=True, timeout=100)
                evidence['reader_exit'] = reader.returncode
                evidence['reader_output'] = reader.stdout.strip()
                evidence['reader_error'] = reader.stderr.strip()
                print(reader.stdout.strip(), flush=True)
                reports = [json.loads(line) for line in reader.stdout.splitlines() if line.startswith('{')]
                if any(report['version'] == '2.5.0' for report in reports):
                    evidence['result'] = 'public_discovery_and_signed_report_passed'
                    break
                evidence['result'] = 'public_announcement_passed_report_not_retrieved'
                if attempt < 2:
                    time.sleep(2)
        finally:
            publisher.terminate()
            try:
                publisher.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                publisher.kill(); publisher.communicate()
    (ROOT / '.build/public-discovery-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))
    if evidence['result'] != 'public_discovery_and_signed_report_passed':
        raise SystemExit(2)


if __name__ == '__main__':
    main()
