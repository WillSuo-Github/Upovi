# Upovi 0.4.6 download center and completion acceptance

Download tasks now expose pause/continue, automatic reconnect/retry, persisted results and explicit fresh-source recovery after restart. Actual signed PKG execution/recovery and protected-helper termination followed by a guest OS reboot passed in a disposable macOS VM. See [behavior and acceptance](DOWNLOAD-CENTER-AND-ACCEPTANCE.md) and [version-specific evidence](evidence/0.4.6-completion.json).

149 local tests passed (134 core, 15 store). Product revision `b327595` passed CI on macOS 14 ARM, macOS 15 Intel and macOS 26 ARM. The Developer ID signed universal bundle, fresh archive extraction and signed feed/archive verification passed. [0.4.6 experimental preview](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.4.6) and its signed public latest feed are published. Actual Sparkle 0.4.5 build 11 → 0.4.6 build 12 replacement/relaunch passed inside the disposable VM, with the resulting bundle signature valid.

A fresh host 0.4.6 global-P2P 24-hour observation started at 2026-10-26 17:30:24 Asia/Shanghai; it is running, not accepted. The operator intentionally stopped the older 0.4.2 run after about 17 hours to switch to the latest candidate; its records are retained without transferring duration. The owner chose to perform physical sleep/wake, actual host interface changes and privileged energy sampling later. Apple notarization remains deferred. This iteration follows direct-main delivery; older sections below are historical and keep their original scope.

---

# Upovi 0.4.5 diagnostics and sources development readiness

Settings now provides local diagnostic preview/export with default inventory redaction and classified source/operation failures. Source coverage adds exact LiveHub and PlayCover repositories, stable VSCodium cask mapping, and correct renamed/platform-specific Homebrew app artifact handling. See [behavior and validation](DIAGNOSTICS-AND-SOURCES.md) and [version-specific evidence](evidence/0.4.5-diagnostics-sources.json).

141 local tests passed (128 core, 13 store), together with native report preview/save/cancel and opt-in/reset acceptance. Product revision 9e2529c passed CI on macOS 14 ARM, macOS 15 Intel and macOS 26 ARM. The signed universal bundle, fresh ZIP extraction and signed feed/archive verification passed. Results and exact artifact identity are recorded in the evidence file. Existing PKG execution, interruption/reboot, long-observation and distribution boundaries retain their original scope. Direct commits go to main.

---

# Upovi 0.4.4 download and cleanup development readiness

Verified artifact caching now supports HTTP byte-range resume across retries and restarts. Completed administrator transactions expose protected usage inspection and confirmed authorized cleanup, with durable recovery revocation before deletion. See [behavior and validation](DOWNLOAD-RESUME-AND-CLEANUP.md) and [version-specific evidence](evidence/0.4.4-resume-cleanup.json).

127 local tests, a real public HTTPS cancel/resume and isolated authorized administrator cleanup passed. Product revision 1318b7f passed CI on macOS 14 ARM, macOS 15 Intel and macOS 26 ARM; the signed universal bundle, fresh ZIP extraction and signed feed/archive verification passed. Exact native helper lineage and boundaries are recorded in the evidence file. Actual PKG execution, administrator interruption/reboot, newer-version long observation, publication and notarization retain their separate boundaries. Direct commits go to main.

---

# Upovi 0.4.3 resilient update development readiness

Exact-source coverage, durable batch records and explicit rechecked retry, per-version skip/snooze, text release notes and extra scan locations are implemented. Actual isolated native multi-application replacement, checksum-failure continuation and a successful retry have been exercised. See [workflow details](RESILIENT-UPDATES.md) and [version-specific evidence](evidence/0.4.3-resilient-updates.json).

Earlier evidence retains its original version and scope. Administrator/PKG execution, download-byte resume, protected-backup pruning and public distribution boundaries remain open. The existing 0.4.2 observation continues independently.

---

# Upovi 0.4.2 toolbar and batch update development readiness

Refresh now rescans and checks every application. Update all reviews and executes a serial source-confirmed update batch, with visible manual-only items, per-app results and safe stop behavior. See [toolbar behavior](TOOLBAR-UPDATES.md) and [version-specific evidence](evidence/0.4.2-toolbar-updates.json). Direct commits go to main; no pull request is required for this project.

Earlier evidence below retains its original version and acceptance boundaries.

---

# Upovi 0.4.1 global P2P development readiness

Settings now has one global P2P switch controlling discovery and sharing for the full scanned inventory. Fresh installations default on; legacy application-specific consent is not silently expanded. The current user explicitly enabled the combined global scope. Application-level P2P controls are removed.

The signed universal candidate passed 81 local tests, isolated automatic/private protocol regressions, native switch/off-socket/restart acceptance, and original/fresh-extracted signature plus signed-feed/archive verification. Current-source CI and the new global 24-hour observation are recorded in [0.4.1 evidence](evidence/0.4.1-global-p2p.json). The observation has started; it is not accepted. The release/feed remains unpublished and notarization deferred.

See [global behavior and validation](GLOBAL-P2P.md). Previous daily-workflow, administrator and release evidence below retains its version-specific scope; its outstanding acceptance requirements still apply.

---

# Upovi 0.4.0 development readiness

P2P mechanism expansion is deferred. Daily-use and administrator installation work is staged in draft PR [#1](https://github.com/WillSuo-Github/Upovi/pull/1), not published as a release.

| Area | Evidence | Remaining boundary |
| --- | --- | --- |
| Sources | Same-machine sample improved from 21 unsupported entries to 8, including one synthetic fixture | Seven real apps still need a reliable adapted/configured source; not universal coverage |
| Login startup | Actual signed-app toggle off → on → off, no registration errors | Login/reboot launch itself not accepted |
| Retained-copy cleanup | Native cancellation and Trash confirmation on a synthetic fixture; current app retained | Interrupted transactions protected; no privileged-backup pruning |
| Self-update | Sparkle, signed feed/archive tooling and nested packaging implemented | Feed publication and genuine old-to-new replacement pending |
| Administrator app installation/recovery | Authorized production bootstrap/helper: isolated signed 2.0.3 → 2.0.4 → 2.0.3, resulting signatures valid | Native install-button, interruption/reboot and full PKG execution remain open |
| PKG validation | Real official package SHA-256, matching developer, Gatekeeper and signed matching app payload passed | Package scripts not executed; main-app restore cannot undo system side effects |
| Automated checks | 73 local tests and isolated protocol regressions passed | CI results are revision-specific; see aggregate evidence |
| Long observation | Stopped 2026-10-25 23:26:25 after about 22 minutes / 22 samples when the observed PID disappeared; not accepted | Timer completion, CPU/RSS and sampled traffic do not establish complete UX/energy acceptance |
| Distribution | Developer ID universal candidate and signed feed staged locally | Apple notarization remains deferred; no release/feed publication |

See [daily readiness](DAILY-READINESS.md), [administrator design](ADMINISTRATOR-INSTALLATION.md), and [aggregate evidence](evidence/0.4.0-daily-readiness.json). Earlier-version results below retain their original scope.

---

# Upovi 0.3.2 release readiness

| Area | State | Boundary |
| --- | --- | --- |
| Community false-claim policy | Implemented; local 50-test suite and native synthetic UI passed | Peer signatures and counts still do not prove truthful installs; source compromise and wrong custom-source configuration remain possible |
| Update counts and list | Source candidates only | Community-only 999.0 stays visible as an unverified lead, but count remains zero; source 2.0 yields one update independently |
| Notifications | Source-only planning and deduplication, tested against injected peer claims | No new actual OS notification sent; previous real Notification Center delivery acceptance belongs to 0.3.1 |
| Confidence labels | Single unverified, multiple keys unverified, source matches | Matching version/build grants no peer authority; custom/catalog sources are not developer signatures |
| Native UI | Actual store/core/views, isolated synthetic entry point and settings, scoped screenshot inspected | Fixture suppresses networking/scanning/scheduled tasks; real public P2P path was accepted separately on 0.3.1 |
| Compatibility | Final product CI passed on macOS 14 ARM, macOS 15 Intel and macOS 26 ARM | [CI run](https://github.com/WillSuo-Github/Upovi/actions/runs/39978142697): 50 tests, both isolated protocol regressions, native tool compilation and native bundle build per system |
| Signed preview | [0.3.2 beta 1](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.3.2-beta.1), universal Developer ID | Strict original/extracted signature and ZIP checksum passed; notarization deferred |
| 24-hour observation | Previous 0.3.1 run interrupted after about 15 h 22 min; not accepted | Normal termination at 2026-10-24 13:16:55 Asia/Shanghai, trigger unknown; observer stopped at 13:17:17. [Evidence](evidence/0.3.1-interrupted-soak.json); no 0.3.2 long-run acceptance |

Artifact: `dist/0.3.2/Upovi-0.3.2.zip`; SHA-256 `42624477445afd7cc4df4c9cdd60743c39b80e3ffe48f671ddd025db9c1ee13c`; embedded revision `525314febbcbe08e87c5ed78ccd22fc262d6b504`, build 5. Signing Team `NT9VR9C9HY`, x86_64 + arm64, hardened runtime, trusted timestamp 2026-10-23 23:25:57 Asia/Shanghai. The package was created in a separate output directory. The running 0.3.1 binary hash and PID were verified unchanged.

See [community trust policy](COMMUNITY-TRUST.md), [aggregate 0.3.2 evidence](evidence/0.3.2-community-trust.json) and [validation](VALIDATION.md). The earlier physical-device, installation, notification and long-observation evidence below is explicitly scoped to 0.3.1. Physical sleep and notarization remain deferred; actual interface switching, direct energy measurement and a real consenting user cohort remain open.

---

# Upovi 0.3.1 release readiness

This is an experimental signed preview. Implementation, observed behavior and acceptance are separate facts.

| Area | State | Boundary |
| --- | --- | --- |
| Scanner and source adapters | Live source check passed, including scheduled execution | 69 normal apps plus two isolated fixtures; source coverage is not universal |
| Public automatic discovery | Two physical Macs on user-confirmed independent networks passed both directions | Signed DHT records succeeded; direct publisher count was zero; truthful installation and Sybil resistance are unsolved |
| Native P2P flow | Read remote 8.4.2 lead; publish synthetic 1.0; independent reader verified; stop sharing during sync passed | One selected signed synthetic fixture; no real application inventory published |
| Preferences | Real quit/cold restart, private file permissions and corrupt-startup fail-closed behavior passed | Corrupt data is preserved; unreadable legacy defaults cannot be recovered automatically |
| ZIP/DMG installation and recovery | Actual native download, cancel, confirm, history and restore passed | Official Rectangle fixture 2.0.3 → 2.0.4 → 2.0.3 in an isolated directory; no normal user app replaced |
| Notifications | Rejection path and actual Notification Center delivery query passed | System permission explicitly authorized; banner not visually confirmed; app notification switch restored off |
| Scheduler and menu bar | Ten-minute P2P and fifteen-minute source checks observed; menu open action reopened closed main window | AXPress on status icon itself failed; physical pointer opening was not retested |
| 24-hour observation | Interrupted, not accepted: 922 samples over about 15 h 22 min | System records a voluntary normal termination; no matching new crash report found. Trigger unknown. UI coverage was limited during lock; traffic tail incomplete. [Evidence](evidence/0.3.1-interrupted-soak.json) |
| Sleep, network changes, energy | Physical sleep deferred by owner; same-client routing resets passed separately | No active interface change or direct energy measurement accepted; CPU/RSS/traffic are supporting metrics |
| macOS and Intel | [Final product CI passed](https://github.com/WillSuo-Github/Upovi/actions/runs/39963985467) | macOS 14 ARM, macOS 15 Intel, macOS 26 ARM; 40 unit tests, isolated automatic/private protocol regressions, native acceptance-tool compilation and bundle build on each |
| Distribution | [0.3.1 beta 1](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.3.1-beta.1), universal Developer ID test package | Apple notarization explicitly deferred; signing does not establish notarization |

## Fixed during actual acceptance

On the local Mac, UserDefaults reported an inaccessible preferences path and normal relaunch lost settings. The app now stores known preferences atomically in a bounded, private application-support plist, migrates readable legacy values, surfaces write failures and preserves corrupt files while starting public features disabled. Five persistence tests and real local/remote restart checks cover this change.

Active sharing previously became impossible to stop while synchronization was busy. The active switch now remains usable; disabling it cancels the sync and stops service/publication. The UI immediately explains that cached public records remain until expiration. Actual native cancellation was verified on the final product source.

## Signed test artifact

- ZIP: `dist/Upovi-0.3.1.zip`; checksum: `dist/Upovi-0.3.1.zip.sha256`.
- SHA-256: `0c07eafee2964327d344f105c8c62c5c67c06f69f185abc644fbe08362942a75`.
- Embedded product revision: `3a71874706417e14eeee2559dcf65ecd87f83b26`. Later evidence/harness-only changes do not change this product binary.
- `x86_64 arm64`; Developer ID Team `NT9VR9C9HY`; hardened runtime and trusted timestamp (2026-10-23 21:46:59 Asia/Shanghai).
- Checksum and strict signature verification passed for the original bundle and a fresh ZIP extraction. No notarization/stapling submitted.

See [native acceptance evidence](evidence/0.3.1-native-acceptance.json), [two-physical-Mac evidence](evidence/0.3.1-two-physical-macs.json), and [validation history](VALIDATION.md). This is an advisory public network; missing records never prove an app current. Sustained public-index poisoning and forged installation claims remain possible.
