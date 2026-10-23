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
| 24-hour observation | Running from 2026-10-23 21:55:17 Asia/Shanghai | Review after 2026-10-24 21:55:17; no full-duration pass claimed; gaps and collector/runtime logs require review |
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
