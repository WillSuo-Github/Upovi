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
