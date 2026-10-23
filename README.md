# Upovi

A native, open-source macOS application update detector with opt-in public P2P version discovery and verified application replacement.

**SwiftUI · Swift 6 · macOS 14+ · MIT · Experimental 0.3.1**

[Download the signed universal test preview](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.3.0-beta.1). Apple notarization is deferred; this is an experimental test package. The release includes its source revision, checksum, validation results, and remaining acceptance boundaries.

## What it does

- Scans `/Applications` and `~/Applications` without launching scanned applications.
- Checks developer Sparkle appcasts, Homebrew's official catalog using exact declared bundle IDs, curated identity mappings, and supported GitHub releases. Unknown apps can be assigned an HTTPS appcast or official GitHub repository in the detail panel.
- Distinguishes source-reported updates, community leads, unsupported sources, and failed checks. An empty result is never proof that all applications are current.
- Downloads eligible ZIP/DMG updates, verifies archive integrity, matching application/developer identity, nested code signatures, version and native executable compatibility, and Gatekeeper acceptance. Installation requires an explicit confirmation and retains the old app for recovery.
- Provides a menu bar entry, opt-in scheduled checks and notifications, source settings, recent-check history, and installation/recovery history.
- Automatically discovers opted-in public publishers using BitTorrent DHT. No invitation, account, publisher-key exchange, or Upovi relay is required.

## Build and run

Install Xcode with Swift 6 command-line tools, then:

```sh
./script/build_and_run.sh
```

This builds and ad-hoc signs `dist/Upovi.app` for local development. The Codex Run action uses the same entrypoint. Open `Package.swift` in Xcode to edit. The installed end-user app does not require Homebrew, Python, or Xcode; ZIP extraction links Apple's system libarchive. Header notices are in `THIRD-PARTY-NOTICES.md`.

## Public community discovery

1. Select up to twenty applications with the table's P2P checkboxes.
2. Enable public discovery on the P2P page.
3. Separately opt into publicly sharing those selected versions if desired. **Discovery and sharing both default off.**
4. Higher community versions appear as advisory leads; verify them with the developer. They never supply download URLs or authorize installation.

Public records contain bundle ID, version/build, channel, self-reported Team ID, observation time, and expiry. They exclude paths, usernames, device names, app display names, and binaries. Records are unencrypted and readable by anyone. Topic hashes are predictable; node identities and traffic can be correlated across applications, and peers can see IP addresses. This is not an anonymous network.

BEP 5 membership discovers endpoints. A rotating, sharded BEP 44 directory supplies untrusted public-key pointers, allowing new readers to fetch individually signed DHT reports without inbound connectivity to a publisher. All valid index replicas are merged within bounded lookups; reserved cache sampling and independent direct-peer sampling improve continuity. Report sequence floors survive restarts while retained locally.

**Availability and truthfulness remain best effort.** Public directory slot keys are intentionally public coordination material, so anyone can overwrite or crowd pointers. Signatures authenticate a publisher key, not a real installation, independent human, or official release. Replica merging, rotation, limits, and replay protection do not solve sustained poisoning or Sybil attacks. Working outbound UDP and available records are required. IPv6, coordinated hole punching, port mapping, and relay fallback are not implemented.

The native app attempts public synchronization every ten minutes while enabled and running. Wake/network changes reset routing. Stopping sharing stops new service/publication; already cached public records cannot be recalled immediately. Reports expire within twenty-four hours and may be evicted by DHT nodes earlier. Receiving replay history retains at most 2048 publisher/topic marks for thirty days since the last accepted sequence advance.

See `docs/P2P-PROTOCOL.md` and `SECURITY.md` for details.

## Installation and recovery

Eligible sources offer **Download and verify update**. After verification, a separate confirmation requests closing the target application and replacing it. Upovi never force-kills an app with unsaved work. The old bundle is retained beside the destination as a hidden `.upovi-backup-<id>.app`; journal entries are under `~/Library/Application Support/Upovi/Installations`. Settings → History and recovery exposes available backups and interrupted transactions. Backups are not automatically deleted.

Only HTTPS ZIP/DMG application updates with a SHA-256 or verifiable installed Sparkle Ed25519 key are eligible. The incoming bundle ID and Team ID must match, its code signature and version must validate, its native executable must support this Mac and OS, and Gatekeeper must accept it. Archive extraction rejects traversal, unsafe symlinks, duplicate members, and bounded size/time violations. DMGs are mounted read-only. Quarantine is retained.

App Store updates, PKG/script installers, unsigned apps, unverified archives, privileged replacements, ambiguous assets, and Upovi self-replacement use the official source/manual workflow. Community reports cannot offer installation. Rolling back an app does not roll back its data format; save documents first. A restore refuses to overwrite a newer external update.

## Checks and evidence

```sh
swift test
python3 script/test_automatic_discovery.py
python3 script/test_dht_exchange.py
./script/build_and_run.sh --verify
```

An explicit public-network check publishes **synthetic metadata only**:

```sh
python3 script/test_public_discovery.py
```

`UpoviPeer check-sources --summary-file <path>` checks local application sources without publishing inventory to P2P. Its optional verbose output remains local and should not be attached wholesale to issues. `discover --evidence-file <path>` exports synthetic/public reports and separate DHT/direct counts. Use `--state-file <path>` for persistent diagnostic sequence history and separate files for concurrent processes.

See `docs/VALIDATION.md` for measured results, `docs/CROSS-NETWORK-TEST.md` for multi-host acceptance, and `docs/RELEASE-READINESS.md` for outstanding release conditions. Unit tests and one-host public tests do not replace physical-device, sleep/wake, real-community, or twenty-four-hour acceptance.

## Native acceptance

`script/acceptance/native_ui.swift` is a developer-only native accessibility controller for explicitly authorized UI checks. It targets Upovi and its notification controls; compile it with `swiftc`. It never requests Accessibility permission itself. Its snapshots may contain installed application metadata; keep raw snapshots local.

`script/acceptance/soak.py --help` describes the 24-hour observation harness. It observes an already configured native app, records aggregate process/UI metrics and per-process network counters, and does not change preferences, prevent sleep, restart a failed app, or declare a pass merely because a timer ended. Review sampling gaps and the runtime log before acceptance.

App preferences are stored atomically with private permissions in `~/Library/Application Support/Upovi/settings-v1.plist`. Known earlier UserDefaults keys migrate on first creation when readable. An unreadable/corrupt settings file is preserved and public features start disabled; write failures are surfaced in the app.

## Distribution

```sh
UPOVI_UNIVERSAL=1 UPOVI_SIGNING_IDENTITY='Developer ID Application: …' ./script/package_release.sh
```

This produces a signed universal app and ZIP. Add `UPOVI_NOTARY_PROFILE=<existing-keychain-profile>` to submit the app to Apple, require an Accepted result, staple its ticket, and verify Gatekeeper. Credentials remain in Keychain. A signed-only artifact is not a notarized release; do not bypass macOS security warnings to run it.

## Contributing

See `CONTRIBUTING.md` and `SECURITY.md`. Private v1 invitation commands remain diagnostic compatibility tools, documented in `docs/P2P-PRIVATE-V1.md`; they are not the application's public discovery flow. Never commit identity JSON, invitation files, installed inventories, or `.local` contents.

Protocol references: [BEP 5](https://www.bittorrent.org/beps/bep_0005.html), [BEP 44](https://www.bittorrent.org/beps/bep_0044.html). Source adapters: [Homebrew JSON](https://formulae.brew.sh/docs/api/), [GitHub releases](https://docs.github.com/en/rest/releases/releases), [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
