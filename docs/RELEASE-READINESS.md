# Upovi 0.3.0 release readiness

This is an experimental preview. Do not equate implementation with acceptance.

| Area | State | Boundary |
| --- | --- | --- |
| Native scanner and source adapters | Implemented; live one-Mac source check passed | 69 scanned: 22 App Store, 26 supported direct-distribution apps, 21 unsupported; source availability is not universal coverage |
| Public DHT automatic discovery | Implemented; isolated, one-host public, and independent-network VM tests passed | Sustained index poisoning, Sybil identities, and truthful-installation attestation remain unsolved |
| Durable replay protection | Implemented and tested | 2048 receiver marks, 30-day retention; local-state removal/eviction resets protection for forgotten entries |
| ZIP/DMG installation and recovery | Implemented; real signed Rectangle fixture updated and restored | Isolated directory only; normal user applications were not replaced; PKG, elevation, and self-update are unsupported |
| Scheduler, network recovery, menu bar, notifications, history | Implemented | Full 24-hour, physical sleep/wake, notification delivery, and energy/traffic acceptance remain pending |
| Native UI | General/P2P settings and empty history inspected | Main P2P page automation and full installation-sheet interaction need final acceptance |
| Minimum OS and Intel | Three-system CI running | macOS 14 ARM, macOS 15 Intel, macOS 26 ARM; final workflow result pending |
| Public repository / CI / preview release | Public repository and CI published | https://github.com/WillSuo-Github/Upovi; final signed test package is being refreshed |
| Developer ID signing | Universal Developer ID test package verified once; refreshing final revision | Final checksum and source revision must be recorded after packaging |
| Apple notarization | Deferred by owner | Explicit instruction: finish the signed test package first; notarization credentials will be supplied later |
| Physical cross-network and real community | One physical Mac to independent macOS VM passed | Two physical Macs and real-user acceptance remain pending; direct publisher count was zero |

The public index remains experimental advisory infrastructure, not a trusted release catalog. Missing observations or failed checks never imply an app is up to date.
