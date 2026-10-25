# Contributing

Build with Xcode command-line tools and Swift 6 on macOS 14 or newer.

```sh
swift test
python3 script/test_automatic_discovery.py
python3 script/test_dht_exchange.py
./script/build_and_run.sh --verify
```

Use synthetic application identities for public-network tests. Never attach identity JSON, invitation files, Keychain material, installed inventories, or the entire `.local` directory to an issue. Public DHT tests are explicit manual checks, not routine tests for forks.

Source adapters must match exact application identities. Keep unsupported, failed, partial, and successfully current results distinct. Community observations cannot provide download descriptors or authorize installation. A matching peer-reported Team ID is not developer attestation.

Installer changes require tests for archive traversal/symlinks, integrity rejection, identity checks, interrupted replacement recovery, and refusing rollback over an unrelated external update. Preserve rollback material. Do not remove quarantine or bypass Gatekeeper. Administrator/PKG work follows the explicitly requested design in `docs/ADMINISTRATOR-INSTALLATION.md`: a protected, verified per-operation helper, system authorization, signed payload checks and separate application-recovery boundaries. Do not add a persistent privileged service or broaden supported paths without a separate design. Real privileged execution must have its own acceptance evidence.

CI checks macOS 14 Apple Silicon, macOS 15 Intel, and macOS 26. A build target is not physical-device or long-running acceptance; document evidence boundaries.
