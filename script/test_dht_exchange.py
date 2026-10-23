#!/usr/bin/env python3
"""Two separate native clients against an isolated UDP BEP 44 test node.

No installed application metadata or identity is sent to the public network.
The test node deliberately does not stand in for a public-network acceptance test.
"""
import hashlib
import json
import pathlib
import socket
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent


def encode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, dict):
        return b"d" + b"".join(encode(k) + encode(value[k]) for k in sorted(value)) + b"e"
    return b"l" + b"".join(map(encode, value)) + b"e"


def decode(data):
    def read(pos):
        marker = data[pos:pos + 1]
        if marker == b"i":
            end = data.index(b"e", pos)
            return int(data[pos + 1:end]), end + 1
        if marker in (b"d", b"l"):
            result = {} if marker == b"d" else []
            pos += 1
            while data[pos:pos + 1] != b"e":
                item, pos = read(pos)
                if marker == b"d":
                    value, pos = read(pos)
                    result[item] = value
                else:
                    result.append(item)
            return result, pos + 1
        end = data.index(b":", pos)
        length = int(data[pos:end])
        return data[end + 1:end + 1 + length], end + 1 + length
    value, end = read(0)
    assert end == len(data)
    return value


def main():
    subprocess.run(["swift", "build", "--product", "UpoviPeer"], cwd=ROOT, check=True)
    bin_dir = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
    binary = str(pathlib.Path(bin_dir) / "UpoviPeer")
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    udp.settimeout(0.2)
    records = {}
    counters = {"gets": 0, "puts": 0}
    stop = threading.Event()
    node_id = hashlib.sha1(b"upovi-isolated-test-node").digest()

    def serve():
        while not stop.is_set():
            try:
                data, address = udp.recvfrom(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            query = decode(data)
            args = query[b"a"]
            response = {b"id": node_id, b"token": b"test-token", b"nodes": b""}
            if query[b"q"] == b"get":
                counters["gets"] += 1
                response.update(records.get(args[b"target"], {}))
            elif query[b"q"] == b"put":
                assert args[b"token"] == b"test-token"
                assert len(encode(args[b"v"])) <= 1000
                target = hashlib.sha1(args[b"k"] + args.get(b"salt", b"")).digest()
                previous = records.get(target)
                if previous:
                    assert args[b"seq"] > previous[b"seq"]
                records[target] = {k: args[k] for k in (b"k", b"v", b"seq", b"sig")}
                counters["puts"] += 1
            udp.sendto(encode({b"t": query[b"t"], b"y": b"r", b"r": response}), address)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="upovi-test-") as directory:
            key = str(pathlib.Path(directory) / "identity.json")
            def run(*args):
                result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=40)
                if result.returncode:
                    raise AssertionError(result.stderr)
                return result.stdout
            run("identity", "--output", key)
            network = ["--bootstrap", f"127.0.0.1:{udp.getsockname()[1]}", "--allow-local"]
            for version in ("2.4.1", "2.5.0"):
                published = run("publish", "--identity", key, "--bundle", "app.upovi.synthetic-test", "--version", version, *network)
                assert "storage_acknowledgements=1" in published, published
                fetched = run("fetch", "--invite", key + ".invite", "--bundle", "app.upovi.synthetic-test", *network)
                report = json.loads(fetched.splitlines()[0])
                assert report["version"] == version, fetched
                assert "signature=valid" in fetched
            print(json.dumps({"result": "passed", "isolated_udp_exchange": True, "independent_client_processes": True,
                              "updates_read": ["2.4.1", "2.5.0"], **counters}))
    finally:
        stop.set()
        thread.join(timeout=1)
        udp.close()


if __name__ == "__main__":
    main()
