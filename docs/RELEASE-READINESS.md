# Upovi 0.4.10 build 202610280001

Product revision `cfaaab5` localizes the interface into 34 languages with Xcode String Catalogs (Simplified Chinese source; other languages machine-translated and not natively reviewed), follows the system locale, mirrors version arrows and disclosure chevrons in right-to-left layouts, renames the per-app action to “Update”, and accepts Google Chrome updates through a reviewed Developer ID–bound download rule (Team `EQHXZ8M8AV`, `dl.google.com/chrome/mac/universal/stable/`). Test-only revision `d59e8f0` makes two message assertions language-independent after they failed on the macos-14 runner. All 201 local Xcode tests passed with the test language set to both zh-Hans and en; 8 release-metadata tests and three macOS CI jobs passed. Isolated real-application acceptance updated an official Chrome 156.0.8078.48 copy to 156.0.8078.74 from Google’s DMG, confirmed it current, and restored it.

[The signed universal release](https://github.com/WillSuo-Github/Upovi/releases/tag/build-202610280001) and signed public latest feed are published. Apple notarization, ticket stapling and Gatekeeper passed. All five public assets match the verified local bytes; the extracted public app, archive and feed signatures, notarization ticket and Gatekeeper checks passed. See [release evidence](evidence/0.4.10-build-202610280001.json). Automatic right-to-left mirroring under a real Arabic/Hebrew system language, native translation review, self-update and long-run runtime acceptance were not performed by this publication.

---

# Upovi 0.4.10 build 202610270005

Product revision `bfd5be3` runs batch updates concurrently (default five, Settings range 1–8), shows per-row progress, transferred size, speed and remaining time, and replaces the floating download pill with an overall progress card. Administrator and App Store steps pass through a serial gate. Concurrent requests for one artifact now share a single download. All 200 local Xcode tests, 8 release-metadata tests and three macOS CI jobs passed. Isolated real-application acceptance updated three official Rectangle 2.0.3 copies to 2.0.4 concurrently, including checksum failure and retry; see [concurrent update validation](VALIDATION-CONCURRENT-UPDATES-2026-10-27.md).

The [signed universal release](https://github.com/WillSuo-Github/Upovi/releases/tag/build-202610270005) and signed public latest feed are published. Apple notarization, ticket stapling and Gatekeeper passed. All five public assets match the verified local bytes; the extracted public app, archive and feed signatures, notarization ticket and Gatekeeper checks passed. See [release evidence](evidence/0.4.10-build-202610270005.json). Concurrent administrator/App Store installation with real prompts, light appearance, Reduce Motion, self-update and long-run runtime acceptance were not performed by this publication.

---

# Upovi 0.4.10 build 202610270004

Product revision `4460527` removes the sidebar P2P entry and Community heading, leaving Updates, All Applications, Downloads and History & Recovery. A remembered P2P destination now opens Updates on startup. P2P behavior and settings are unchanged. Native UI inspection using an isolated fixture confirmed all four entries, migration from the remembered P2P page and working Downloads navigation. All 195 local Xcode tests, 8 release-metadata tests and three macOS CI jobs passed.

The [signed universal release](https://github.com/WillSuo-Github/Upovi/releases/tag/build-202610270004) and signed public latest feed are published. Apple notarization, ticket stapling and Gatekeeper passed. All five public assets match the verified local bytes; the extracted public app, archive and feed signatures, notarization ticket and Gatekeeper checks passed. See [release evidence](evidence/0.4.10-build-202610270004.json). The normal installed Upovi copy was not replaced and no new self-update or long-run runtime acceptance was performed by this publication.

---

# Upovi 0.4.10 build 202610270003

Product revision `d9fb561` adds exact official Mos 3.5.0 ad hoc-signature migration to its pinned signed developer identity, preserves strict archive/payload validation and extends recovery to both identities. All 195 local Xcode tests, 8 release-metadata tests and three macOS CI jobs passed. Real isolated core and native UI upgrade/restore acceptance passed; resource-modified and re-signed modified legacy copies were rejected. The normal installed Mos copy and Accessibility permissions were unchanged; actual privileged migration execution was not exercised.

The [signed universal release](https://github.com/WillSuo-Github/Upovi/releases/tag/build-202610270003) and signed public latest feed are published. Apple notarization, ticket stapling and Gatekeeper passed. All six public assets match the verified local bytes; the extracted public bundle, archive and feed signatures, notarization ticket and Gatekeeper checks passed. See [migration design and acceptance](MOS-LEGACY-MIGRATION.md) and [release evidence](evidence/0.4.10-build-202610270003.json). Current-host Upovi self-update, physical sleep/network, energy and long-run acceptance remain separate checks.

---

# Upovi 0.4.10 build 202610270002

Product revision `0b049fd` adds centralized source mappings, matching-source download supplementation and a reviewed Apple Developer ID verification route for official direct-application downloads without archive proofs. All 189 local Xcode tests, 8 release-numbering tests and all three macOS CI jobs passed. The universal Developer ID package passed Apple notarization, ticket stapling and Gatekeeper assessment. The [release](https://github.com/WillSuo-Github/Upovi/releases/tag/build-202610270002) and signed public latest feed are published. Re-downloaded public archive, feed, checksum, source revision and artifact-validation bytes match the verified local artifact; the extracted public bundle passes nested signatures, ticket and Gatekeeper checks.

Real isolated Typora `1.14.9 (7785)` to `1.14.15 (7789)` and iStat Menus `7.30 (2282)` to `7.50 (2356)` main-application replacement, fresh current-version checks and old-version restores passed. The exact iStat package/source-version exception preserves strict bundle/build checking. Typora's upgraded executable launched, but first-launch window inspection timed out and remains unverified. Background components, drivers and scripts were not installed or tested. This publication did not replace the normal installed Upovi app or exercise a new Sparkle self-update. See [source/trust acceptance](UPDATE-SOURCE-TRUST.md) and [release evidence](evidence/0.4.10-build-202610270002.json). Long-run, physical sleep/network and energy acceptance remain separate unfinished checks.

---

# Upovi 0.4.10 build 202610270001

The marketing version remains 0.4.10. Routine updates now use Shanghai-date build numbers and separate `build-<build>` GitHub tags and version/build archive filenames. Product revision `d164d01` passed the numbering tests and all three macOS CI jobs. Its Developer ID universal package passed Apple notarization, ticket stapling and Gatekeeper assessment. The [date-build release](https://github.com/WillSuo-Github/Upovi/releases/tag/build-202610270001) and signed public latest feed are published; public ZIP/feed/checksum bytes match the verified final artifact, and the extracted app passes signature, ticket and Gatekeeper checks.

Actual host Sparkle replacement/relaunch from 0.4.10 build 16 to 0.4.10 build 202610270001 passed. The native alert distinguished both builds under the unchanged marketing version; the About panel shows `0.4.10 (202610270001)`. All four installed executable files match the public artifact. `/Applications/Upovi.app` and the project-local `dist/Upovi.app` contain this notarized date build. See [version-specific evidence](evidence/0.4.10-build-202610270001.json). Notarization and this update do not complete the separate long-run, physical sleep/network or energy checks.

---

# Upovi 0.4.10 startup update checks

Startup now performs one complete inventory scan and source check even when periodic checks are disabled. Previously the initial view task scanned inventory only, leaving a fresh installation at the unchecked landing page after the activity indicator disappeared. A store-owned one-time entry point starts the existing cancellable refresh pipeline and survives view-task completion; populated stores and repeated view appearances do not start another initial pass. Scanning, source preparation and check progress remain visible. Periodic scheduling keeps its existing opt-in preference. Offline startup retains the scanned inventory and explains why source checking could not run.

Five regression tests cover startup with periodic checks disabled, reentry during scanning, cancellation, offline startup and populated-store preservation. All 180 local tests passed. Independent fresh-settings native acceptance reproduced the original scan-only stop with 72 host applications and zero checks; the fixed view completed 72 real source checks without pressing a check button, with periodic checks and P2P both disabled. Source failures remain source failures; completion does not imply every origin returned an update. Release, notarization and public old-to-new acceptance are recorded separately in version-specific evidence.

Product revision `52bf864` passed all three macOS CI jobs. The Developer ID universal archive passed Apple notarization and ticket stapling; the [0.4.10 release](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.4.10) and signed public latest feed (build 16) are published. Re-downloaded public ZIP/feed/checksum bytes match the verified artifact, and the extracted app passes signature, ticket and Gatekeeper checks. Actual host Sparkle 0.4.9 build 15 → 0.4.10 build 16 download/install/relaunch passed. The new application automatically checked all 72 host applications on relaunch, and its executable bytes match the published archive. `/Applications/Upovi.app` and the project-local `dist/Upovi.app` contain this notarized build. See [version-specific evidence](evidence/0.4.10-startup-checks.json).

---

# Upovi 0.4.9 notarized distribution

Build 15 makes the notarized distribution available to existing installations through Sparkle. Packaging explicitly signs Sparkle's nested services and updater tools, all installation helpers and the outer application with Developer ID, Hardened Runtime and secure timestamps. Each component retains its own entitlements except debugger access. The archive must pass Apple notarization, ticket stapling and Gatekeeper assessment before publication; the final stapled ZIP and appcast are signed together. Publication and actual old-to-new replacement are recorded separately in version-specific evidence. Physical sleep/network/power and long-run acceptance are not established by notarization.

Product revision `316067f` passed all three macOS CI jobs after fixing duplicate C module-map discovery on older Xcode versions. All 175 local tests passed. The [0.4.9 release](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.4.9) and public latest signed feed are published. Re-downloaded public ZIP/feed/checksum bytes match the verified artifact; the extracted universal app passes nested signature, stapled-ticket and Gatekeeper checks. Actual host Sparkle 0.4.8 build 14 → 0.4.9 build 15 download/install/relaunch passed at `/Applications/Upovi.app`, and the resulting executable bytes match the public artifact. The project-local `dist/Upovi.app` also contains this notarized version. See [version-specific evidence](evidence/0.4.9-notarized-release.json). This completes notarization for 0.4.9; earlier deferred-notarization notes below describe their original historical artifacts.

---

# Upovi 0.4.8 in-application Store update preview

Supported native Mac App Store installations now have in-application source checks, explicit check-and-update and shared batch review. A protected signed helper verifies the installed Store identity and selected product before initiating only an update through Apple's existing account/services. Current/no-op results are distinct from installed upgrades. Store operations have no Upovi retained-copy rollback or download pause; failed handoffs remain unconfirmed. The normal flow no longer opens the App Store window for supported apps.

173 local tests and read-only host Store detection passed. With the owner's explicit Shazam authorization, the native review/start flow invoked the protected helper and Apple accurate Store check. It returned current, with one completed item and zero failures; Shazam remained 2.11.0 (821). No old-to-new Store installation was exercised. The same authorized check passed again on the final clean-source Developer ID signed universal artifact, and its current detail remained visible after closing the result. Product revision `8b6d1a3` passed macOS 14 ARM, 15 Intel and 26 ARM CI. Nested signatures, fresh archive extraction and signed feed/archive verification passed. The [0.4.8 experimental signed preview](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.4.8) is published. Its public latest signed feed is build 14; re-downloaded public ZIP/feed hashes and signatures match the verified artifact. Publication is recorded separately in the version-specific evidence. See [Store integration](APP-STORE-UPDATES.md) and [evidence](evidence/0.4.8-app-store-updates.json). Physical sleep/network/power checks and notarization remain owner-deferred. The older 0.4.6 collector was already interrupted; its app process was later normally terminated to launch this signed 0.4.8 candidate, without inheriting observation duration.

---

# Upovi 0.4.7 source refresh and reliability

Manual refresh now invalidates catalog freshness and revalidates metadata with the origin. Scheduled checks use a five-minute catalog lifetime instead of twenty-four hours. An older in-flight catalog response cannot overwrite a newer refresh. Source HTTP requests use a bounded in-memory validator cache, serial per-origin requests, cancellation and bounded transient retries. Explicit throttling headers establish cooldowns; a plain 403 is reported as denied and never invented as a rate-limit diagnosis. Failed revalidation cannot silently reuse stale success.

Read-only public HTTPS acceptance observed both Homebrew and GitHub return 200 for the initial request and 304 for forced conditional revalidation. A new 71-app source scan reported zero failed/partial checks in that run, compared with three failed and five partial previously; transient network behavior can change and this is not proof that every 403 is eliminated. Four real manual-only applications now have exact official entry points; one synthetic fixture remains unsupported. No app was installed by this scan.

See [behavior and validation](SOURCE-REFRESH-AND-RELIABILITY.md) and [version-specific evidence](evidence/0.4.7-source-reliability.json). Product revision `a5adf1b` passed all three macOS CI jobs. Its Developer ID universal bundle, fresh ZIP extraction and signed feed/archive verification passed. The [0.4.7 experimental preview](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.4.7) and public latest signed feed (build 13) are published. Actual guest Sparkle 0.4.6 → 0.4.7 replacement/relaunch, resulting signature verification, two toolbar refreshes and both official manual-entry displays passed. The 0.4.6 baseline collector disappeared after about 52 minutes/53 samples, last recorded at 2026-10-26 18:22:24 Asia/Shanghai. Its unchanged application process and binary were still present at that review; the collector exit cause is unknown. The app was later normally stopped to launch the 0.4.8 candidate. This observation is not accepted and does not validate 0.4.7. Physical sleep/wake, host interface changes, privileged energy sampling and notarization retain their owner-deferred status. Direct-main delivery continues.

---

# Upovi 0.4.6 download center and completion acceptance

Download tasks now expose pause/continue, automatic reconnect/retry, persisted results and explicit fresh-source recovery after restart. Actual signed PKG execution/recovery and protected-helper termination followed by a guest OS reboot passed in a disposable macOS VM. See [behavior and acceptance](DOWNLOAD-CENTER-AND-ACCEPTANCE.md) and [version-specific evidence](evidence/0.4.6-completion.json).

149 local tests passed (134 core, 15 store). Product revision `b327595` passed CI on macOS 14 ARM, macOS 15 Intel and macOS 26 ARM. The Developer ID signed universal bundle, fresh archive extraction and signed feed/archive verification passed. [0.4.6 experimental preview](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.4.6) and its signed public latest feed are published. Actual Sparkle 0.4.5 build 11 → 0.4.6 build 12 replacement/relaunch passed inside the disposable VM, with the resulting bundle signature valid.

A host 0.4.6 global-P2P observation started at 2026-10-26 17:30:24 Asia/Shanghai. Its collector disappeared after about 52 minutes/53 samples, last recorded at 18:22:24; the raw summary remained stale running. The original application PID 85261 and binary were still running unchanged at review, so this is a collector interruption, not evidence of an application crash. The app was later normally stopped to launch the 0.4.8 candidate. The cause is unknown and the run is not accepted. Three completed source checks reported zero failures; 45/53 samples lacked a visible window. Records are retained without restarting or inheriting duration. The follow-up automation was removed after this review. The operator intentionally stopped the older 0.4.2 run after about 17 hours to switch to the latest candidate; its records are retained without transferring duration. The owner chose to perform physical sleep/wake, actual host interface changes and privileged energy sampling later. Apple notarization remains deferred. This iteration follows direct-main delivery; older sections below are historical and keep their original scope.

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
