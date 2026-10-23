#!/usr/bin/env python3
"""Explicit public-network smoke test. Publishes one encrypted synthetic version record."""
import datetime
import json
import pathlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    subprocess.run(["swift", "build", "--product", "UpoviPeer"], cwd=ROOT, check=True)
    bin_dir = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
    binary = str(pathlib.Path(bin_dir) / "UpoviPeer")
    evidence = {"at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "scope": "synthetic record, public DHT, separate publisher and reader processes on one Mac",
                "cross_network_two_mac_validation": False}
    with tempfile.TemporaryDirectory(prefix="upovi-public-test-") as directory:
        key = str(pathlib.Path(directory) / "identity.json")
        def run(*args):
            result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=100)
            if result.returncode:
                raise RuntimeError(result.stderr.strip())
            return result.stdout.strip()
        run("identity", "--output", key)
        evidence["publish"] = run("publish", "--identity", key, "--bundle", "app.upovi.synthetic-public-test", "--version", "0.1.20261023")
        print(evidence["publish"], flush=True)
        for attempt in range(3):
            try:
                fetched = run("fetch", "--invite", key + ".invite", "--bundle", "app.upovi.synthetic-public-test")
                record = json.loads(fetched.splitlines()[0])
                assert record["version"] == "0.1.20261023"
                evidence["fetch"] = fetched
                evidence["result"] = "passed"
                break
            except RuntimeError:
                if attempt == 2:
                    raise
                time.sleep(2)
    target = ROOT / ".build/public-dht-evidence.json"
    target.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
