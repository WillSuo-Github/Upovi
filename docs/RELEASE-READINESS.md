# Upovi 0.3.0 release readiness

This is an experimental preview. Do not equate implementation with acceptance.

| Area | State | Boundary |
| --- | --- | --- |
| Native scanner and source adapters | Implemented; live one-Mac source check passed | 69 scanned: 22 App Store, 26 supported direct-distribution apps, 21 unsupported; source availability is not universal coverage |
| Public DHT automatic discovery | Implemented; isolated, one-host public, and independent-network VM tests passed | Sustained index poisoning, Sybil identities, and truthful-installation attestation remain unsolved |
| Durable replay protection | Implemented and tested | 2048 receiver marks, 30-day retention; local-state removal/eviction resets protection for forgotten entries |
| ZIP/DMG installation and recovery | Implemented; real signed Rectangle fixture updated and restored | Isolated directory only; normal user applications were not replaced; PKG, elevation, and self-update are unsupported |
| Scheduler, network recovery, menu bar, notifications, history | Implemented | Full 24-hour, physical sleep/wake, notification delivery, and energy/traffic acceptance remain pending |
| Native UI | Main table and real check action, General/P2P settings and empty history inspected | Main P2P page automation and full installation-sheet interaction need final acceptance |
| Minimum OS and Intel | Passed on all three systems | [Final source CI](https://github.com/WillSuo-Github/Upovi/actions/runs/39952087878): macOS 14 ARM, macOS 15 Intel, macOS 26 ARM; 35 tests, isolated protocol regressions and native bundle build each |
| Public repository / CI / preview release | Public repository, CI, and signed test preview | [Repository](https://github.com/WillSuo-Github/Upovi) · [0.3.0 beta 1](https://github.com/WillSuo-Github/Upovi/releases/tag/v0.3.0-beta.1) |
| Developer ID signing | Universal Developer ID test package verified | `x86_64 arm64`, hardened runtime, timestamp; signed bundle and ZIP-extracted bundle both pass strict verification; source `47c51c9bf5fca61fde81893d370e52c156925557` |
| Apple notarization | Deferred by owner | Explicit instruction: finish the signed test package first; notarization credentials will be supplied later |
| Physical cross-network and real community | One physical Mac to independent macOS VM passed | Two physical Macs and real-user acceptance remain pending; direct publisher count was zero |

The public index remains experimental advisory infrastructure, not a trusted release catalog. Missing observations or failed checks never imply an app is up to date.

## Signed test artifact

- File: `dist/Upovi-0.3.0.zip` (about 1.8 MB), with `dist/Upovi-0.3.0.zip.sha256`.
- SHA-256: `f94a62d36d68d6dd753c0c097f03ca0f5b1cf12dcda97f67ac51c27807a45657`.
- Signature: Developer ID Application, Team `NT9VR9C9HY`, hardened runtime and trusted timestamp (2026-10-23 20:16 Asia/Shanghai). No additional entitlements requested.
- Both original and ZIP-extracted bundles pass `codesign --verify --strict --all-architectures`; archive checksum verification passed. The signed native app was launched and its main table inspected with 69 scanned apps and public sharing/discovery disabled.
- Source revision embedded in `Contents/Info.plist`: `47c51c9bf5fca61fde81893d370e52c156925557`. Later evidence-only documentation commits do not change that artifact.
- Apple notarization and stapling were intentionally not submitted; a valid Developer ID signature is not a notarization ticket.

The signed app's actual **Check for updates** toolbar action completed at 20:20 Asia/Shanghai: 69 scanned apps and ten apps with source updates; the action returned to enabled and the check timestamp appeared. This did not enable P2P sharing or install an update.
