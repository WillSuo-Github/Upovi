# Upovi

A native, open-source macOS application update detector with globally controlled public P2P version discovery and sharing and verified application replacement.

**SwiftUI · Swift 6 · macOS 14+ · MIT · Experimental 0.4.10 (202610270005)**

[Download the signed and notarized universal test preview](https://github.com/WillSuo-Github/Upovi/releases/latest). Version 0.4.10, build 202610270005 includes Developer ID signing and a stapled Apple notarization ticket, and passes Gatekeeper. This remains an experimental test package; notarization does not establish the remaining runtime acceptance checks. The release includes its source revision, checksum and validation results.

## What it does

- **Refresh and check** rescans `/Applications` and `~/Applications`, then checks the complete new inventory for updates, independently of search and list filters. Background P2P does not disable refresh.
- **Update all** reviews all source-confirmed updates once, then downloads, verifies and installs eligible applications sequentially. Per-app results and unfinished batches survive relaunch; retry rechecks current apps and sources before presenting a new confirmation. Failures do not suppress later apps, and official/manual-only updates are listed explicitly.
- Supports skipping a specific version/build, postponing update reminders, viewing source release notes, and selecting extra scan directories in Settings. The policy applies consistently to update counts, bulk actions and notifications; global P2P participation remains independent.
- Provides a download task center with pause/continue, network-reconnect continuation, bounded automatic retry and private history. Interrupted tasks require fresh source checks after restart; installation confirmation is preserved. See [download center and acceptance](docs/DOWNLOAD-CENTER-AND-ACCEPTANCE.md).
- Exports a previewable local diagnostic JSON with source outcomes, classified errors and operation phases. Application identifiers are optional; paths, URLs, raw logs and credentials are excluded. See [diagnostics and source coverage](docs/DIAGNOSTICS-AND-SOURCES.md).
- Manual refresh revalidates source metadata instead of reusing a day-old catalog. Source requests use bounded memory caching, conditional validation, per-origin queues and server-directed cooldowns. Failures never silently become successful stale checks.
- Checks supported Mac App Store installations and offers in-application check/update and shared batch review through Apple Store services. Store updates require the owning Apple Account, may require native authentication, and have no Upovi rollback/pause. See [Store integration and acceptance](docs/APP-STORE-UPDATES.md).
- Checks developer Sparkle appcasts, Homebrew's official catalog using exact declared bundle IDs, curated identity mappings, and supported GitHub releases. Unknown apps can be assigned an HTTPS appcast or official GitHub repository in the detail panel.
- Distinguishes source-reported updates, community leads, unsupported sources, and failed checks. An empty result is never proof that all applications are current.
- Downloads eligible ZIP/DMG updates using source archive proofs or a reviewed official-origin/Apple Developer ID route. Both paths check application/developer identity, nested code signatures, exact version/build, native executable compatibility and Gatekeeper acceptance. Installation requires individual or batch confirmation and retains the old main app for recovery. See [source and trust rules](docs/UPDATE-SOURCE-TRUST.md).
- Provides a menu bar entry, opt-in scheduled checks and notifications, system-backed login-at-startup settings, source filters/settings, recent-check history, and installation/recovery history.
- Resumes canceled/interrupted ZIP, DMG and PKG downloads when the HTTPS server provides a strong validator; retry revalidates the final artifact before installation. See [download recovery](docs/DOWNLOAD-RESUME-AND-CLEANUP.md).
- Shows retained-copy sizes and moves eligible copies to Trash only after confirmation. Interrupted recovery material is protected.
- Uses Sparkle 2.10.0 for Upovi itself, with signed feeds and archives, opt-in automatic checks, and installation-aware relaunch deferral. The public feed and genuine 0.4.5 → 0.4.6, 0.4.6 → 0.4.7, 0.4.8 → 0.4.9 and 0.4.9 → 0.4.10 replacement/relaunch have been accepted; artifacts keep separate evidence.
- Scans installed applications and checks their update sources once on launch, independently of optional periodic checks. Startup progress remains visible through inventory scanning, source preparation and version checks; opening another window does not repeat the initial check.
- Offers Upovi-managed administrator installation for signed application replacements and inspectable signed PKGs. Each operation requests macOS authorization, uses a verified protected helper, and retains a protected main-app backup. Completed protected backups can be inspected and permanently cleaned after confirmation and authorization; failed/interrupted transactions remain protected. PKG script side effects are not rolled back; see [the administrator design](docs/ADMINISTRATOR-INSTALLATION.md).
- Automatically discovers opted-in public publishers using BitTorrent DHT. No invitation, account, publisher-key exchange, or Upovi relay is required.

## Build and run

Open `Upovi.xcodeproj` in Xcode 16 or newer, select the **Upovi** scheme and **My Mac**, then press **Run (⌘R)**. This is a native macOS SwiftUI application target with Debug/Release configurations, an AppIcon asset catalog, native installer-tool targets, and shared test/archive actions. Use **Test (⌘U)** for both test suites and **Product → Archive** for a release archive. Choose your signing team in Signing & Capabilities when signing for distribution.

For the command-line build/run workflow:

```sh
./script/build_and_run.sh
```

This uses `xcodebuild` and stages the built, ad-hoc signed application at `dist/Upovi.app`. The Codex Run action uses the same entrypoint. Xcode builds the app bundle, embeds Sparkle and both installer tools, and runs a build phase to embed the checksum-pinned Store bridge and third-party licenses. First-time package resolution and Store bridge download require network access. The installed end-user app does not require Homebrew, Python, or Xcode; ZIP extraction links Apple's system libarchive. Header notices are in `THIRD-PARTY-NOTICES.md`.

The checked-in project opens directly without XcodeGen. `project.yml` is its reproducible specification; after changing project structure, run `xcodegen generate` and commit both files. Existing SwiftPM tools and tests remain available through `Package.swift` for diagnostic/acceptance scripts. The main app development entrypoint is `Upovi.xcodeproj`. See [Xcode project details](docs/XCODE-PROJECT.md) for targets and build settings.

Current implementation and acceptance boundaries are tracked in [release readiness](docs/RELEASE-READINESS.md). The 0.4.10 build 202610270005 notarized preview and signed public latest feed are published. Batch updates run up to five applications concurrently with per-row progress, speed and remaining time; administrator and App Store steps remain serialized. All 200 local tests, 8 release-numbering tests and three macOS CI jobs passed; isolated real Rectangle concurrent acceptance passed (see [concurrent update validation](docs/VALIDATION-CONCURRENT-UPDATES-2026-10-27.md)). Public asset bytes and extracted signature, ticket and Gatekeeper checks passed. See [release evidence](docs/evidence/0.4.10-build-202610270005.json). The prior [Mos migration](docs/MOS-LEGACY-MIGRATION.md) and [source/trust acceptance](docs/UPDATE-SOURCE-TRUST.md) retain their recorded scope, including the Typora first-launch UI gap. Physical sleep/wake, interface switching, energy sampling and long-run acceptance remain separate unfinished checks.

## Public community discovery

1. Open Settings → P2P. **Enable P2P network** is the application's only participation switch; there are no per-application controls.
2. A fresh installation defaults on: all scanned apps automatically participate in both discovery and public version-metadata sharing. Existing users' off choices and earlier app-specific scopes migrate to off, rather than silently expanding their public inventory. Enabling the new switch opts into the full scanned inventory.
3. Turning the switch off cancels synchronization and stops publication, serving and the UDP transport. Previously cached public records cannot be recalled immediately and expire under the protocol's existing limits.
4. Higher community versions remain unverified advisory leads. They never increase the available-update count, enter the available-updates list, send update notifications, supply download URLs, or authorize installation.
5. Use **Check update sources** to check the configured sources. Only a matching version/build receives a **Source matches** label; independent source candidates drive counts and notifications once per application.

Single-key reports and repeated reports from multiple distinct publisher keys are labeled separately. Duplicate keys do not increase corroboration; multiple keys are not proof of independent users. Source matches are recomputed from current check results, so removing a source or a failed recheck removes the match. Homebrew is a catalog and custom sources are user-configured; a source match is not cryptographic developer endorsement. See [community trust policy](docs/COMMUNITY-TRUST.md).

Public records contain bundle ID, version/build, channel, self-reported Team ID, observation time, and expiry. They exclude paths, usernames, device names, app display names, and binaries. Records are unencrypted and readable by anyone. Topic hashes are predictable; node identities and traffic can be correlated across applications, and peers can see IP addresses. This is not an anonymous network.

BEP 5 membership discovers endpoints. A rotating, sharded BEP 44 directory supplies untrusted public-key pointers, allowing new readers to fetch individually signed DHT reports without inbound connectivity to a publisher. All valid index replicas are merged within bounded lookups; reserved cache sampling and independent direct-peer sampling improve continuity. Report sequence floors survive restarts while retained locally.

**Availability and truthfulness remain best effort.** Public directory slot keys are intentionally public coordination material, so anyone can overwrite or crowd pointers. Signatures authenticate a publisher key, not a real installation, independent human, or official release. Replica merging, rotation, limits, and replay protection do not solve sustained poisoning or Sybil attacks. Working outbound UDP and available records are required. IPv6, coordinated hole punching, port mapping, and relay fallback are not implemented.

The native app attempts public synchronization every ten minutes while enabled and running, rotating bounded batches across all scanned application identities so apps after the first twenty are not starved. Wake/network changes reset routing. Stopping sharing stops new service/publication; already cached public records cannot be recalled immediately. Reports expire within twenty-four hours and may be evicted by DHT nodes earlier. Receiving replay history retains at most 2048 publisher/topic marks for thirty days since the last accepted sequence advance.

See `docs/GLOBAL-P2P.md`, `docs/P2P-PROTOCOL.md` and `SECURITY.md` for details.

## Installation and recovery

Eligible sources offer **Download and verify update**. After verification, a separate confirmation requests closing the target application and replacing it. Upovi never force-kills an app with unsaved work. The old bundle is retained beside the destination as a hidden `.upovi-backup-<id>.app`; journal entries are under `~/Library/Application Support/Upovi/Installations`. The main window's History and recovery section exposes available backups and interrupted transactions. Backups are not automatically deleted. History shows retained-copy sizes and offers confirmed Trash cleanup for completed transactions; interrupted transactions cannot be cleaned through that action. New restores also track the displaced newer app as a retained copy.

HTTPS ZIP/DMG application updates and direct PKG downloads need a SHA-256 or verifiable installed Sparkle Ed25519 key. PKGs additionally need a matching Developer ID Installer signature, Gatekeeper acceptance and a matching signed app payload; administrator destinations are restricted to direct children of /Applications. The incoming bundle ID and Team ID must match, its code signature and version must validate, its native executable must support this Mac and OS, and Gatekeeper must accept it. Archive extraction rejects traversal, unsafe symlinks, duplicate members, and bounded size/time violations. DMGs are mounted read-only. Quarantine is retained.

Unsupported Store installations, unsigned/unverifiable artifacts, script-only or uninspectable packages, unsupported administrator destinations, and ambiguous assets use the official source/manual workflow. The normal app replacement path refuses Upovi self-replacement; Upovi uses its dedicated Sparkle updater. Community reports cannot offer installation. Rolling back an app does not roll back its data format; save documents first. A restore refuses to overwrite a newer external update.

## Checks and evidence

```sh
xcodebuild -project Upovi.xcodeproj -scheme Upovi -destination 'platform=macOS' test
python3 script/test_automatic_discovery.py
python3 script/test_dht_exchange.py
./script/build_and_run.sh --verify
```

An explicit public-network check publishes **synthetic metadata only**:

```sh
python3 script/test_public_discovery.py
```

`UpoviPeer check-sources --summary-file <path>` checks local application sources without publishing inventory to P2P. Use `--details-file <private-local-path>` for per-app adapter gaps. Its details and optional verbose output remain local and should not be attached wholesale to issues. `discover --evidence-file <path>` exports synthetic/public reports and separate DHT/direct counts. Use `--state-file <path>` for persistent diagnostic sequence history and separate files for concurrent processes.

See `docs/VALIDATION.md` for measured results, `docs/CROSS-NETWORK-TEST.md` for multi-host acceptance, and `docs/RELEASE-READINESS.md` for outstanding release conditions. Unit tests and one-host public tests do not replace physical-device, sleep/wake, real-community, or twenty-four-hour acceptance.

## Native acceptance

`script/acceptance/native_ui.swift` is a developer-only native accessibility controller for explicitly authorized UI checks. It targets Upovi and its notification controls; compile it with `swiftc`. It never requests Accessibility permission itself. Its snapshots may contain installed application metadata; keep raw snapshots local.

`script/acceptance/soak.py --help` describes the 24-hour observation harness. It observes an already configured native app, records aggregate process/UI metrics and per-process network counters, and does not change preferences, prevent sleep, restart a failed app, or declare a pass merely because a timer ended. Review sampling gaps and the runtime log before acceptance.

App preferences are stored atomically with private permissions in `~/Library/Application Support/Upovi/settings-v1.plist`. Known earlier UserDefaults keys migrate on first creation when readable. An unreadable/corrupt settings file is preserved and public features start disabled; write failures are surfaced in the app.

## Distribution

Routine updates keep the marketing version unchanged. Build numbers use Shanghai time in `YYYYMMDDNNNN` form: `202610270001`, `202610270002`, then `202610280001` on the next day. Only change the marketing version when the owner explicitly prepares a new formal version. Allocate one build per update; rebuilding or retrying the same update keeps that number:

```sh
python3 script/release_metadata.py bump-build
python3 script/release_metadata.py show
```

The bump command synchronizes `Resources/Release.json` and `Config/Release.xcconfig` while preserving the marketing version. Use `bump-build --dry-run` to preview the next number. Routine GitHub tags use `build-<build>` and archives use `Upovi-<version>-<build>.zip`, so multiple updates under one marketing version have separate download URLs. The stable latest appcast URL stays unchanged; Sparkle compares `sparkle:version` (the build) while displaying `sparkle:shortVersionString` (the marketing version). Preparing a build does not publish it.

```sh
UPOVI_UNIVERSAL=1 UPOVI_SIGNING_IDENTITY='Developer ID Application: …' ./script/package_release.sh
```

This produces a signed universal app and ZIP. Set `UPOVI_OUTPUT_DIR` to an absolute alternative output directory to stage another version without replacing a running test bundle. Add `UPOVI_NOTARY_PROFILE=<existing-keychain-profile>` to submit the app to Apple, require an Accepted result, staple its ticket, and verify Gatekeeper. Credentials remain in Keychain. A signed-only artifact is not a notarized release; do not bypass macOS security warnings to run it.

Version/build settings are in `Config/Release.xcconfig`; release tooling rejects drift from `Resources/Release.json`. Read the exact archive name and publication tag with `python3 script/release_metadata.py show --field archive` and `show --field tag`. Feed URL and public key come from `Resources/Release.json`. After producing the signed ZIP, run `script/generate_update_feed.sh` and `python3 script/verify_release.py <output-directory> --require-notarization` to generate and verify the signed feed and archive. The feed script resolves the pinned Sparkle package tools when needed. The private Sparkle key remains in Keychain under the configured account. Publish the ZIP and feed together only within the owner's requested distribution scope and after acceptance.

## Contributing

See `CONTRIBUTING.md` and `SECURITY.md`. Private v1 invitation commands remain diagnostic compatibility tools, documented in `docs/P2P-PRIVATE-V1.md`; they are not the application's public discovery flow. Never commit identity JSON, invitation files, installed inventories, or `.local` contents.

Protocol references: [BEP 5](https://www.bittorrent.org/beps/bep_0005.html), [BEP 44](https://www.bittorrent.org/beps/bep_0044.html). Source adapters: [Homebrew JSON](https://formulae.brew.sh/docs/api/), [GitHub releases](https://docs.github.com/en/rest/releases/releases), [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
