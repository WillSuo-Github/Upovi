# Validation: Upovi 0.3.2 community-claim policy, 2026-10-23

- Local full suite: **50 tests, 0 failures**, including ten new trust-policy regressions. A real Ed25519-signed invented 999.0 report passes protocol decoding but cannot become a source update or notification. One hundred publisher identities cannot grant update authority. Tests also cover version/build mismatches, missing/duplicate/expired identities, source removal/failure, wrong application identity, partial-source success and notification deduplication.
- Local production build passed. Native synthetic acceptance compiled the actual AppStore/core/views with a synthetic entry point and isolated preferences URL. Public networking, scanning, scheduled checks and actual notification submission were suppressed in the fixture. The normal running app and its preferences were not used by this fixture.
- Actual UI checks: only community 999.0 / repeated 2.0 gives **zero** available updates and an empty available-updates page; supplying a synthetic source 2.0 build 200 gives **one** update and a source-match label for 2.0, while 999.0 remains unverified; removing the source returns to **zero**. Community reports remain visible on P2P/all-app details with no installation button. A scoped window screenshot was visually checked for source/lead separation, count and text layout. [Aggregate evidence](evidence/0.3.2-community-trust.json).
- Notification submission uses the same tested source-only planning policy and cannot add peer candidates to notification content or persisted deduplication state. Existing real macOS Notification Center delivery acceptance belongs to 0.3.1; no new system notification was sent for this synthetic policy test.

The real 24-hour observer remains pinned to **0.3.1 / 3a71874706417e14eeee2559dcf65ecd87f83b26**. It was not restarted or replaced, and cannot establish long-run acceptance of 0.3.2. Source matches refer to existing independently fetched developer/configured/catalog sources, not cryptographic developer endorsement. [Policy details](COMMUNITY-TRUST.md).

---

# Validation: Upovi 0.3.1, 2026-10-23

Product revision: `3a71874706417e14eeee2559dcf65ecd87f83b26`. [Final CI](https://github.com/WillSuo-Github/Upovi/actions/runs/39963985467) passed on macOS 14 ARM, macOS 15 Intel and macOS 26 ARM: **40 unit tests, 0 failures**, independent automatic discovery, legacy private exchange, native acceptance-controller compilation and native bundle build on each. The five added persistence tests cover fresh-reader restoration, private permissions, failed replacement preserving old data, corrupt/oversized input, symlink rejection and blocked writes. Public-contact filtering includes the CGNAT/Tailscale address range.

## Actual native and physical-device results

- **Two physical Macs, both directions:** Mac16,10 / Apple M4 and Mac16,8 MacBook Pro / M4 Pro, both macOS 27.0.1, on user-confirmed independent networks. Fresh readers matched synthetic publishers `5f997aa96bc4` (8.4.1) and `ec41c585b973` (8.4.2), each through one verified DHT publisher with zero direct publishers, rejected reports and failed records. Three remote same-client routing resets also recovered the matching record. No invitations, identities, public keys, endpoint addresses or custom bootstrap were transferred. Default contact filtering excludes Tailscale/CGNAT peers; this does not attest absence of system VPN exit routing. [Sanitized evidence](evidence/0.3.1-two-physical-macs.json).
- **Native P2P UI:** public discovery read remote 8.4.2 for one selected signed synthetic fixture. The detail showed a community lead and no community download/install control. Explicit synthetic-only native sharing obtained 8 topic, 8 directory and 5 storage acknowledgements; an independent reader verified native publisher `c5dd2e6547f6`, version 1.0 build 1, alongside the remote record. On the final app, the sharing switch stayed enabled during synchronization and immediately stopped sharing when clicked; retained-cache warning appeared. Final sharing is off.
- **Native installation and restore:** official Rectangle test copy in a separate test directory: download/verify, cancel (remained 2.0.3), re-download, confirm replacement (actual bundle 2.0.4), history, restore confirmation, actual restored 2.0.3. Backup and restored journal state exist. Normal user apps were not replaced or launched. Earlier core checks independently verified download SHA-256, nested signatures, native executable support, quarantine and Gatekeeper.
- **Settings bug found and repaired:** normal quit/relaunch exposed a real UserDefaults persistence failure on this host. The application-support plist fix restored navigation, discovery consent/scope, automatic-check setting, notification preference and history across a normal cold launch. File mode 0600, parent 0700. A controlled corrupt startup showed a visible load error, disabled public discovery and preserved the exact corrupt bytes; the original test settings were then restored. Remote physical Mac separately passed navigation persistence and cold window restoration on `daecddc`; its page-internal AX controls remain unreadable.
- **Notifications:** rejected authorization kept the switch off and showed a reason. After explicitly authorized system permission, the native test action returned a matching delivered notification from Apple's Notification Center query, with `notification test submitted delivered=true` at 21:32:28.944 Asia/Shanghai. The native success message was visible. No banner was captured, so this is Notification Center delivery acceptance, not a visual banner assertion. Persisted update-notification deduplication survived relaunch. Application notifications were restored off; OS permission remains allowed.
- **Schedulers and menu:** actual P2P discovery timestamps advanced 20:49 → 20:59; a fifteen-minute scheduled source check completed 21:04:31 with 71 scanned apps (two fixtures included), 11 source updates and zero source failures. The menu's open action reopened the closed main window without changing the process. Direct AXPress on the menu-bar icon returned an automation error; pointer opening itself was not retested. The source editor actually rejected an HTTP appcast in its sheet, displayed the validation error and was cancelled without saving.
- **Signed distribution:** final universal Developer ID bundle and fresh ZIP extraction passed strict verification; checksum matched. Source and SHA-256 are in [release readiness](RELEASE-READINESS.md). The packaging script now refuses to overwrite its running app bundle. A prior build-over-running-binary interruption was build interference and is excluded from stability acceptance.

User explicitly approved native Accessibility/XCTest alternatives after SkyComputerUseService repeatedly crashed during navigation. Upovi stayed alive during those control-service failures. Local native AX and one scoped P2P-window screenshot supplied the later UI evidence; raw snapshots and full settings remain ignored/local. The last P2P screenshot was visually checked for layout/privacy/scope but captured a sync in progress, not the returned publisher. [Aggregate native evidence](evidence/0.3.1-native-acceptance.json).

## Long observation and remaining boundaries

A real native **24-hour observer started 2026-10-23 21:55:17 Asia/Shanghai**, with review planned after **2026-10-24 21:55:17**. It samples process identity, CPU time/RSS and native UI each minute and records app-only runtime events and per-process traffic. Discovery is enabled for one synthetic bundle, sharing and notifications off, scheduled source checks every fifteen minutes. It neither prevents sleep nor restarts the app. A timer completion is not a pass: coverage gaps, errors, source/P2P completions, process changes and metric trends must be reviewed. Current status is running, not accepted. Raw observations remain in ignored `.local/physical-acceptance/native-soak-24h`.

A short 10-second harness check passed before the full run; a deliberate sharing-on probe correctly stopped. Neither substitutes for 24 hours. A short `top` sample showed low idle CPU/POWER, but POWER is an OS estimate, not watts. Direct energy measurement, physical sleep/wake (explicitly deferred), actual interface switching and a real consenting community cohort remain open. Same-client routing resets are not physical lifecycle acceptance. IPv6, coordinated NAT traversal, relay fallback, PKG/elevation, self-update and universal source coverage are not implemented; signed public reports do not prove truthful installation or independent humans. Apple notarization is deferred by the owner.

The sections below are historical snapshots; this iteration supersedes their pending native UI, notification and two-physical-Mac statements.

---

# Validation: Upovi 0.3.0, 2026-10-23

## Current iteration

- Local final unit/regression run at **20:12 Asia/Shanghai**: **35 tests passed, 0 failures**. Coverage includes source identity and asset selection, appcast delta exclusion, community download exclusion, bounded ZIP extraction and traversal/link rejection, native Mach-O CPU/OS checks, transactional installation, injected interruption recovery, and refusal to overwrite an externally changed application during restore.
- Independent-process automatic discovery passed, including **ten same-client routing resets**, two signed publishers, offline-publisher DHT storage, wrong-Team isolation, partial/omitted index fallback, directory CAS contention, and replay rejection after reader restart. Legacy encrypted exchange also passed. The reset test exercises socket/routing recreation; it is not physical sleep/wake acceptance.
- Public DHT retest at **19:59 Asia/Shanghai**: six announcement acknowledgements, six signed-record storage acknowledgements, seven directory acknowledgements; fresh reader found one valid synthetic 2.5.0 report. Direct publisher count was zero; 150 routing/index responses are not 150 distinct users.
- **Independent-network result at 20:04 Asia/Shanghai**: a fresh GitHub-hosted macOS 26 runner automatically discovered local publisher `518bdccc3d1f` and verified synthetic version **9.8.7**, without an invitation or transferred publisher key. `dhtPublishers=1`, `directPublishers=0`, `failedRecords=0`, `rejectedReports=0`. This is one physical Mac and a remote macOS VM, not two physical Macs. The successful path used signed cached DHT records; three advertised endpoints were unreachable. Public, synthetic-only evidence is retained in [evidence/0.3.0-cross-host.json](evidence/0.3.0-cross-host.json). The macOS 26 job passed; other jobs in that historical run exposed compatibility issues addressed afterward.
- Real official signed **Rectangle 2.0.3 → 2.0.4 → 2.0.3** acceptance passed in an isolated application directory. Production download, SHA-256, matching developer/bundle identity, nested signatures, native executable compatibility, quarantine and Gatekeeper assessment all passed; replacement retained the original and restore succeeded. The user's normal applications were not replaced or launched. Download SHA-256: `9f820a2e56bd2c27cdda4fb4556de3cbcfcbac052d9eeb2179d49e2dae277abc`.
- Live local source coverage: 69 apps scanned, including 22 App Store apps; among 47 direct-distribution apps, 26 had supported source checks and 21 were unsupported. Status counts: 16 current, 10 apps with updates, 22 App Store, 21 unsupported. Eleven source candidates existed across those ten update apps. No installed inventory was published to P2P or committed.
- The final signed app's main table, General settings, P2P settings, and empty history/recovery UI were inspected. Its actual Check for updates toolbar action completed at 20:20: 69 apps scanned, ten with source updates, completion timestamp visible and the button re-enabled. P2P-main-page input still crashes **SkyComputerUseService**, including the final attempt at 20:12; Upovi remains running. Full P2P-page and installation-confirmation click acceptance is pending. Core installation success does not establish that UI acceptance.

Local detailed logs: `.build/final-tests.log`, `.build/final-discovery.log`, `.build/final-private.log`, `.build/iteration-public.log`, `.build/installer-acceptance.log`, and `.build/source-coverage.json`. Inventory-bearing logs stay ignored. Final source [CI run 39952087878](https://github.com/WillSuo-Github/Upovi/actions/runs/39952087878) passed on macOS 14 ARM, macOS 15 Intel, and macOS 26 ARM: 35 tests, both isolated protocol regressions, and native release bundle build on each. See [RELEASE-READINESS.md](RELEASE-READINESS.md) for distribution state.

## Current acceptance boundaries

Two physical Macs, reverse-network roles, physical sleep/wake, notification delivery, twenty-four-hour native synchronization, traffic/energy measurements, and a real consenting user cohort remain unvalidated. IPv6, coordinated NAT hole punching, relay fallback, PKG/elevation, self-replacement, and universal source coverage are not implemented. The public index cannot establish truthful installation or Sybil resistance. Apple notarization is explicitly deferred by the owner; the requested artifact is a Developer ID signed test package.

The results below are historical snapshots. Current evidence above and release readiness supersede earlier feature and distribution limitations.

---

# Validation: Upovi 0.2.0, 2026-10-23

## Reliability follow-up: 2026-10-23 18:40–18:45 Asia/Shanghai

- Unit/regression tests: **22 passed, 0 failures**. Added durable replay/equal-sequence conflict rejection after restart, invalid-record high-water isolation, outbound sequence persistence and clock rollback, storage corruption/write failures, retention/topic separation, crowded-index sampling quotas, and deterministic stop-sharing-during-preparation coverage.
- Independent-process UDP integration: passed. A partially populated but valid index no longer suppresses direct discovery of a second publisher. A restarted reader retains verified publisher keys when all index entries are hidden and publishers are offline. A signed older report is rejected after a newer report and reader restart. A two-storage-node fixture also proves an older honest index replica remains discoverable alongside a newer valid slot that omits its publisher. CAS and legacy port-scope checks continue passing.
- Public DHT retest started at **18:40:12** with a fresh synthetic topic and identity: 8 topic announcement acknowledgements, 8 index acknowledgements, 8 signed-record storage acknowledgements. A fresh reader obtained one valid signed 2.5.0 report through DHT. `dht_publishers=1`, `direct_publishers=0`, one advertised endpoint was unreachable, and 147 routing/index lookup responses were observed. This is not direct NAT-traversal success or 147 distinct users.
- Legacy encrypted v1 independent-process regression: passed, reading 2.4.1 then 2.5.0.
- Updated native app built and launched successfully. Main-window accessibility inspection again showed 69 scanned apps and P2P disabled. Selecting the P2P page caused SkyComputerUseService to crash again at 18:43:58; Upovi itself remained alive. Full P2P-page interaction acceptance remains outstanding.
- The two-Mac procedure and per-reader JSON evidence output are ready in `CROSS-NETWORK-TEST.md`. They have **not** been executed on two physical Macs.

Follow-up evidence: `.build/resilience-tests.log`, `.build/resilience-integration.log`, `.build/resilience-public.log`, `.build/resilience-private.log`, `.build/resilience-launch.log`, and `.build/automatic-discovery-evidence.json`.

Durable receiver protection is bounded to 2048 publisher/topic marks and thirty days since the last accepted sequence advance. It does not survive clearing local state or eviction, and does not establish truthful installation claims or Sybil resistance. Public slot poisoning remains possible, especially for first-time readers with no remembered publishers. Test fixtures use synthetic metadata only; no real installed inventory was published.

## Original automatic discovery results

| Check | Observed result | Boundary |
| --- | --- | --- |
| Build and launch | Passed | `script/build_and_run.sh --verify`; native app process remains running |
| Unit tests | 15 tests, 0 failures | Public report authenticity/expiry, topic separation, private/public separation, endpoint filtering, cookie scope, directory bounds/rotation, original comparison/parser/scanner regressions |
| Automatic discovery, isolated UDP DHT | Passed | Two independent publisher processes; a fresh reader receives no invitation, publisher key, or contact address |
| Version observations | 2.4.1 and 2.5.0 | Both actual publisher signatures checked; a different Team ID produces no matching publisher |
| Source port handling | Passed | Announced UDP source port matches the peer request service port |
| Direct peer fallback | Passed | Directory hidden by test fixture; fresh reader retrieves two valid reports from discovered peer endpoints |
| DHT-only first-time reader | Passed | Both publishers terminated; a fresh reader still discovers their public keys through the directory and reads two signed records from DHT storage |
| Directory contention | Passed | Two publishers deliberately share one directory shard; both retained, one injected CAS conflict retried successfully |
| Legacy private v1 exchange | Passed | Two independent processes still read 2.4.1, then the updated 2.5.0 encrypted record |
| Public DHT automatic registration | Passed | 8 topic acknowledgements, 8 public publisher-index acknowledgements, 8 signed-report storage acknowledgements |
| Public DHT first-time reader | Passed | Fresh reader with no invitation or publisher identity discovers one publisher and reads a signature-valid 2.5.0 synthetic report |

The successful public test started at **2026-10-23 18:21 Asia/Shanghai**. Its fresh reader found two advertised endpoints and one directory publisher candidate, accepted one actual signed report, and received 153 valid routing/index lookup responses across the different lookups. That response count is not a count of distinct users or independent nodes.

The public test used only a unique `app.upovi.synthetic-discovery.*` bundle ID, a synthetic Team ID, and a temporary test identity. No real installed application inventory was published. The private fixture keys were removed by the runner.

An earlier endpoint-only public test registered successfully but could not read reports from the advertised endpoints on this network. That failure drove the additional BEP 44 publisher-index and report-storage path. It is not treated as a direct-connect success: the final public exchange succeeded through DHT records.

## Evidence

- `.build/community-tests.log`
- `.build/automatic-discovery-evidence.json` and `.build/automatic-test.log`
- `.build/public-discovery-evidence.json` and `.build/public-discovery-test.log`
- `.build/isolated-dht-evidence.log`
- `.build/launch-evidence.log`

The ignored logs are local development evidence. The public test can be rerun with `python3 script/test_public_discovery.py`; it explicitly publishes synthetic metadata.

## Remaining boundaries

- The public test ran separate processes on one Mac using real public DHT nodes. Two physical Macs behind different networks, long-running discovery, sleeping/waking, and node churn are not validated.
- The rotating public index is untrusted and permits arbitrary writers. Sharding, epoch/sequence bounds, CAS retries, and independent publisher signatures are implemented; sustained index poisoning, crowding, and Sybil resistance are not solved. This is an experimental advisory discovery network, not a trusted release catalog.
- Public-sharing flags are new and default off, including migration from v1. No private invitation or read key is advertised. The native UI now removes invitation/contact controls and distinguishes public discovery from public sharing.
- The native main window was inspected and the app remains running. P2P-page UI inspection again crashed the **SkyComputerUseService automation process**, while Upovi remained alive. That screen is not claimed as visually accepted; the service failure does not invalidate the separately executed native protocol tests.
- No actual community user cohort exists in these tests. There must be other opted-in sharers for real application observations to appear.
- Public distribution signing/notarization, Intel/macOS 14 runtime validation, IPv6 routing, automatic installation/rollback, and exhaustive source coverage remain outside this change. Persistent replay protection is now implemented within the follow-up retention limits above.


## Archived v1 baseline: 2026-10-23

### Environment

- Apple Silicon Mac, Xcode 27.1, Swift 6.4, macOS 27 SDK.
- Deployment target: macOS 14. No physical Intel Mac or macOS 14 runtime validation has been performed.
- No third-party package dependencies, hosted account, Upovi server, or paid service was used.

### Observed results

| Check | Result | Evidence boundary |
| --- | --- | --- |
| Native build | Passed | `swift build` and `script/build_and_run.sh --verify` |
| Native app launch | Passed | Foreground SwiftUI window inspected with screenshot and accessibility tree |
| Real application scan | 69 applications | `/Applications` and `~/Applications` on this Mac |
| Real source checks | 3 source-reported updates | Three source-reported updates; per-app installed versions remain in ignored local evidence; no update was installed |
| Unit tests | 9 tests, 0 failures | Comparison, parsing, scanner metadata, compact nodes, signature/encryption, expiry, wrong identity/channel, invitation validation |
| Isolated UDP exchange | Passed | Independent native publisher/reader processes read 2.4.1, then the higher sequence record 2.5.0; four gets and two puts |
| Public DHT lookup | Passed | 16 valid node responses in the diagnostic probe |
| Public DHT storage | Passed | One encrypted synthetic record received 4 storage acknowledgements |
| Fresh public reader process | Passed | Recovered synthetic version 0.1.20261023 and verified its Ed25519 signature; 16 lookup responses |

The public smoke test started at 2026-10-23 17:43 Asia/Shanghai. It used only the bundle ID `app.upovi.synthetic-public-test`, a synthetic Team ID, and an ephemeral test identity. No installed application inventory was published. Temporary test private keys and invitations were deleted by the test runner.

Detailed local logs live in the ignored `.build/` directory: `test-output.log`, `public-dht-evidence.json`, and `scan-evidence.txt`. The scanner output is local and should not be uploaded as part of an issue report.

### v1 validation boundaries

- Two physical Macs on separate home/mobile/corporate networks, restrictive UDP firewalls, prolonged sleep/wake behavior, and longer-term DHT record persistence.
- Complete P2P-screen interaction inspection: switching to that screen caused the SkyComputerUseService automation process to crash (`Array.remove(at:)` assertion). Upovi itself remained running and had no matching app crash report. The main application table and live source-update filter were inspected successfully; the P2P screen is not counted as visually accepted.
- Public distribution signing, notarization, app icon polish, Intel runtime, and a public repository/release.
- At the v1 baseline, automatic discovery was absent; v2 results above supersede this limitation. IPv6 routing and persistent anti-rollback state remain absent.
- Automatic downloading, installing, rollback, and universal application source coverage.

The public test proves distributed public-node record storage and retrieval from one Mac. It does not claim direct sessions between two Macs or universal NAT traversal.
