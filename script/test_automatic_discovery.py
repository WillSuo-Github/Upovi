#!/usr/bin/env python3
"""Independent native publishers/readers; no invitation or publisher key passed to reader."""
import hashlib
import json
import pathlib
import runpy
import select
import socket
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent
CODEC = runpy.run_path(str(ROOT / 'script/test_dht_exchange.py'))
encode, decode = CODEC['encode'], CODEC['decode']


def main():
    subprocess.run(['swift', 'build', '--product', 'UpoviPeer'], cwd=ROOT, check=True)
    binary = str(pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()) / 'UpoviPeer')
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(('127.0.0.1', 0))
    replica = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    replica.bind(('127.0.0.1', 0))
    replicas_enabled = threading.Event()
    replica_index = {}
    stop = threading.Event()
    records, swarms = {}, {}
    counts = {'get_peers': 0, 'announce_peer': 0, 'directory_conflicts': 0}
    index_targets = set()
    first_index_records = {}
    hide_directory = threading.Event()
    errors = []
    node_id = hashlib.sha1(b'upovi-discovery-test-node').digest()

    def serve():
        while not stop.is_set():
            try:
                readable, _, _ = select.select([udp, replica], [], [], 0.2)
                if not readable:
                    continue
                active = readable[0]
                data, address = active.recvfrom(65536)
            except OSError:
                break
            try:
                query = decode(data); args = query[b'a']; method = query[b'q']
                remote_id = hashlib.sha1(b'upovi-replica').digest() if active is replica else node_id
                body = {b'id': remote_id, b'nodes': b'', b'token': b'isolated-token'}
                if replicas_enabled.is_set() and active is udp:
                    body[b'nodes'] = hashlib.sha1(b'upovi-replica').digest() + socket.inet_aton('127.0.0.1') + replica.getsockname()[1].to_bytes(2, 'big')
                if method == b'get':
                    if not (hide_directory.is_set() and args[b'target'] in index_targets):
                        source = replica_index if active is replica and args[b'target'] in index_targets else records
                        body.update(source.get(args[b'target'], {}))
                elif method == b'put':
                    assert args[b'token'] == b'isolated-token'
                    target = hashlib.sha1(args[b'k'] + args.get(b'salt', b'')).digest()
                    if args.get(b'salt') == b'upovi-index-v2':
                        index_targets.add(target)
                        if counts['directory_conflicts'] == 0:
                            counts['directory_conflicts'] += 1
                            active.sendto(encode({b't': query[b't'], b'y': b'e', b'e': [301, b'CAS conflict']}), address)
                            continue
                    if b'cas' in args and target in records and args[b'cas'] != records[target][b'seq']:
                        active.sendto(encode({b't': query[b't'], b'y': b'e', b'e': [301, b'CAS conflict']}), address)
                        continue
                    records[target] = {k: args[k] for k in (b'k', b'v', b'seq', b'sig')}
                    if target in index_targets:
                        first_index_records.setdefault(target, records[target])
                elif method == b'get_peers':
                    counts['get_peers'] += 1
                    body[b'values'] = list(swarms.get(args[b'info_hash'], set()))
                elif method == b'announce_peer':
                    assert args[b'token'] == b'isolated-token'
                    assert args[b'implied_port'] == 1
                    assert args[b'port'] == address[1], 'announcement must originate from the serving UDP port'
                    compact = socket.inet_aton(address[0]) + address[1].to_bytes(2, 'big')
                    swarms.setdefault(args[b'info_hash'], set()).add(compact)
                    counts['announce_peer'] += 1
                active.sendto(encode({b't': query[b't'], b'y': b'r', b'r': body}), address)
            except Exception as error:
                errors.append(repr(error))

    thread = threading.Thread(target=serve, daemon=True); thread.start()
    publishers = []
    publisher_keys = []
    try:
        with tempfile.TemporaryDirectory(prefix='upovi-auto-test-') as directory:
            network = ['--bootstrap', f'127.0.0.1:{udp.getsockname()[1]}', '--allow-local']
            bundle = 'app.upovi.synthetic-auto-test'
            shared_shard = None
            for index, version in enumerate(['2.4.1', '2.5.0']):
                # The printed short ID starts with SHA256(publicKey), also used for
                # directory sharding. Force real multi-writer contention in one shard.
                for attempt in range(64):
                    key = str(pathlib.Path(directory) / f'identity-{index}-{attempt}.json')
                    created = subprocess.run([binary, 'identity', '--output', key], check=True, capture_output=True, text=True)
                    short_id = created.stdout.split('identity=')[1].split()[0]
                    shard = int(short_id[:2], 16) % 4
                    if shared_shard is None or shared_shard == shard:
                        shared_shard = shard
                        break
                else:
                    raise AssertionError('Could not generate two test identities in one directory shard')
                process = subprocess.Popen([binary, 'share-public', '--identity', key, '--bundle', bundle,
                                            '--version', version, '--duration', '120', *network], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                publishers.append(process)
                publisher_keys.append(key)
                ready, _, _ = select.select([process.stdout], [], [], 30)
                assert ready, 'publisher did not announce'
                line = process.stdout.readline()
                assert 'public_announcements=1' in line, line + process.stderr.read() if process.poll() is not None else line
            state = str(pathlib.Path(directory) / 'reader-state.json')
            result = subprocess.run([binary, 'discover', '--bundle', bundle, '--version', '1.0', '--state-file', state, '--require-report', '--evidence-file', str(pathlib.Path(directory) / 'reader-evidence.json'), *network], text=True, capture_output=True, timeout=40)
            assert result.returncode == 0, result.stderr
            observations = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            assert sorted(item['version'] for item in observations) == ['2.4.1', '2.5.0'], result.stdout
            assert 'automatic_publishers=2' in result.stdout, result.stdout
            snapshot = json.loads((pathlib.Path(directory) / 'reader-evidence.json').read_text())
            assert snapshot['dhtPublishers'] == 2 and snapshot['directPublishers'] == 2, snapshot
            assert len({item['publisherID'] for item in snapshot['observations']}) == 2, snapshot
            wrong_team = subprocess.run([binary, 'discover', '--bundle', bundle, '--team', 'OTHER', *network], text=True, capture_output=True, timeout=30)
            assert wrong_team.returncode == 0 and 'automatic_publishers=0' in wrong_team.stdout, wrong_team.stderr
            # Removing directory records forces a fresh reader onto actual peer requests.
            hide_directory.set()
            direct = subprocess.run([binary, 'discover', '--bundle', bundle, '--version', '1.0', '--require-report', *network], text=True, capture_output=True, timeout=40)
            assert direct.returncode == 0 and 'automatic_publishers=2' in direct.stdout, direct.stderr + direct.stdout
            hide_directory.clear()
            # One valid directory publisher must not suppress a second direct peer.
            saved_records = dict(records)
            for target in index_targets:
                record = records.get(target)
                if record and len(record[b'v']) == 2:
                    # Use an earlier genuinely signed slot containing one publisher.
                    records[target] = first_index_records[target]
            partial = subprocess.run([binary, 'discover', '--bundle', bundle, '--require-report', *network], text=True, capture_output=True, timeout=40)
            assert partial.returncode == 0 and 'automatic_publishers=2' in partial.stdout, partial.stderr + partial.stdout
            assert 'directory_candidates=1' in partial.stdout and 'direct_publishers=2' in partial.stdout, partial.stdout
            records.clear(); records.update(saved_records)
            # Persisted verified keys remain usable when all directory pointers disappear
            # and no direct endpoint can help. This is a fresh reader process.
            for process in publishers:
                process.terminate(); process.communicate(timeout=5)
            publishers.clear()
            saved_swarms = dict(swarms); swarms.clear(); hide_directory.set()
            remembered = subprocess.run([binary, 'discover', '--bundle', bundle, '--state-file', state, '--require-report', *network], text=True, capture_output=True, timeout=40)
            assert remembered.returncode == 0 and 'automatic_publishers=2' in remembered.stdout, remembered.stderr + remembered.stdout
            hide_directory.clear(); swarms.update(saved_swarms)
            # No online publisher remains. A new reader must discover public keys from
            # the directory and obtain independently signed records from DHT storage.
            for process in publishers:
                process.terminate(); process.communicate(timeout=5)
            publishers.clear()
            offline = subprocess.run([binary, 'discover', '--bundle', bundle, '--version', '1.0', '--require-report', *network], text=True, capture_output=True, timeout=40)
            assert offline.returncode == 0 and 'automatic_publishers=2' in offline.stdout, offline.stderr + offline.stdout
            # A newer signed observation is remembered; replaying a genuinely signed
            # older observation must be rejected by a completely new reader process.
            report_target = next(target for target, value in records.items()
                                 if target not in index_targets and json.loads(value[b'v'])['version'] == '2.4.1')
            old_report = records[report_target]
            # Preserve a valid older replica containing both publishers. A later
            # writer replaces the primary slot with its own key only.
            replica_index.update({target: records[target] for target in index_targets if target in records})
            for target in index_targets:
                records.pop(target, None)
            updated = subprocess.Popen([binary, 'share-public', '--identity', publisher_keys[0], '--bundle', bundle,
                                        '--version', '2.6.0', '--duration', '120', *network], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            publishers.append(updated)
            ready, _, _ = select.select([updated.stdout], [], [], 30)
            assert ready and 'public_announcements=1' in updated.stdout.readline(), 'updated publisher did not announce'
            newer = subprocess.run([binary, 'discover', '--bundle', bundle, '--state-file', state, '--require-report', *network], text=True, capture_output=True, timeout=40)
            assert newer.returncode == 0 and any(json.loads(line)['version'] == '2.6.0' for line in newer.stdout.splitlines() if line.startswith('{')), newer.stderr + newer.stdout
            updated.terminate(); updated.communicate(timeout=5); publishers.clear(); swarms.clear()
            replicas_enabled.set()
            replicas = subprocess.run([binary, 'discover', '--bundle', bundle, '--require-report', *network], text=True, capture_output=True, timeout=40)
            assert replicas.returncode == 0 and 'automatic_publishers=2' in replicas.stdout and 'dht_publishers=2' in replicas.stdout, replicas.stderr + replicas.stdout
            assert 'directory_candidates=2' in replicas.stdout and 'direct_publishers=0' in replicas.stdout, replicas.stdout
            replicas_enabled.clear()
            records[report_target] = old_report
            replay = subprocess.run([binary, 'discover', '--bundle', bundle, '--state-file', state, *network], text=True, capture_output=True, timeout=40)
            assert replay.returncode == 0 and 'automatic_publishers=1' in replay.stdout and 'rejected_reports=1' in replay.stdout, replay.stderr + replay.stdout
            assert not any(json.loads(line)['version'] == '2.4.1' for line in replay.stdout.splitlines() if line.startswith('{')), replay.stdout
            assert not errors, errors
            evidence = {'result': 'passed', 'automatic_publishers': 2, 'versions': sorted(x['version'] for x in observations),
                        'reader_had_invitation_or_publisher_key': False, 'wrong_team_publishers': 0,
                        'serving_port_matches_announcement': True, 'direct_peer_fallback': True,
                        'fresh_reader_with_publishers_offline': True, 'same_directory_shard_publishers': 2,
                        'partial_valid_index_does_not_suppress_direct_peers': True,
                        'persisted_publishers_survive_missing_index_and_offline_peers': True,
                        'replay_rejected_after_reader_restart': True,
                        'older_honest_replica_survives_newer_omitting_slot': True, **counts}
            (ROOT / '.build/automatic-discovery-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
            print(json.dumps(evidence))
    finally:
        for process in publishers:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.communicate()
        stop.set(); thread.join(timeout=1); udp.close(); replica.close()


if __name__ == '__main__':
    main()
