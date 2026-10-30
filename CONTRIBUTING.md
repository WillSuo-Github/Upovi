# Contributing

Open `Upovi.xcodeproj` in Xcode 16 or newer on macOS 14 or newer. Select the Upovi scheme and My Mac; use Cmd-R to run, Cmd-U to test, and Product > Archive for a release archive. The checked-in project requires no generator to open or build. If you change target membership or build settings through `project.yml`, regenerate with XcodeGen and commit the project alongside the specification.

```sh
xcodebuild -project Upovi.xcodeproj -scheme Upovi -destination 'platform=macOS' test
python3 script/test_automatic_discovery.py
python3 script/test_dht_exchange.py
./script/build_and_run.sh --verify
```

`Package.swift` retains the existing SwiftPM CLI/acceptance workflow, including `swift test`. The native project compiles the same source files; do not create duplicate implementations. Xcode's hosted app tests use the shared scheme's `UPOVI_TEST_HOST=1` environment to isolate preferences and suppress startup inventory scanning, public participation, and Sparkle startup.

Use synthetic application identities for public-network tests. Never attach identity JSON, invitation files, Keychain material, installed inventories, or the entire `.local` directory to an issue. Public DHT tests are explicit manual checks, not routine tests for forks.

Source adapters must match exact application identities. Keep unsupported, failed, partial, and successfully current results distinct. Community observations cannot provide download descriptors or authorize installation. A matching peer-reported Team ID is not developer attestation.

Installer changes require tests for archive traversal/symlinks, integrity rejection, identity checks, interrupted replacement recovery, and refusing rollback over an unrelated external update. Preserve rollback material. Downloaded/prepared applications retain quarantine until a user-confirmed installation. `ApplicationInstallation` may remove only quarantine from the selected bundle after matching its exact identity/version, validating its Apple Developer ID signature and receiving fresh Gatekeeper acceptance. It must not follow symlinks, modify external hard links, clear other metadata or disable system security policy. A rejected assessment must leave quarantine intact. Verify that the installed app launches from its actual installation path. Administrator/PKG work follows the explicitly requested design in `docs/ADMINISTRATOR-INSTALLATION.md`: a protected, verified per-operation helper, system authorization, signed payload checks and separate application-recovery boundaries. Do not add a persistent privileged service or broaden supported paths without a separate design. Real privileged execution must have its own acceptance evidence.

CI checks macOS 14 Apple Silicon, macOS 15 Intel, and macOS 26. A build target is not physical-device or long-running acceptance; document evidence boundaries.
