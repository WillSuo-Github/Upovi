# Upovi 0.3.0 release readiness

This is an experimental preview. Do not equate implementation with acceptance.

| Area | State | Boundary |
| --- | --- | --- |
| Native scanner and source adapters | Implemented; live one-Mac source check passed | 69 scanned: 22 App Store, 26 supported direct-distribution apps, 21 unsupported; source availability is not universal coverage |
| Public DHT automatic discovery | Implemented; isolated and one-host public tests passed | Sustained index poisoning, Sybil identities, and truthful-installation attestation remain unsolved |
| Durable replay protection | Implemented and tested | 2048 receiver marks, 30-day retention; local-state removal/eviction resets protection for forgotten entries |
| ZIP/DMG installation and recovery | Implemented; real signed Rectangle fixture updated and restored | Isolated directory only; normal user applications were not replaced; PKG, elevation, and self-update are unsupported |
| Scheduler, network recovery, menu bar, notifications, history | Implemented | Full 24-hour, physical sleep/wake, notification delivery, and energy/traffic acceptance remain pending |
| Native UI | General/P2P settings and empty history inspected | Main P2P page automation and full installation-sheet interaction need final acceptance |
| Minimum OS and Intel | CI matrix prepared | Local host is Apple Silicon/macOS 27; remote CI results are recorded separately when available |
| Public repository / CI / preview release | Prepared | Publishing, workflow results, and release URLs must be separately confirmed |
| Developer ID signing | Certificate available; packaging prepared | Actual artifact verification must be recorded after packaging |
| Apple notarization | Blocked on credentials | No notarytool Keychain profile found; a Developer ID certificate alone cannot submit a notarization |
| Physical cross-network and real community | Pending | Cloud VM checks, if performed, supplement rather than replace physical-device/user acceptance |

The public index remains experimental advisory infrastructure, not a trusted release catalog. Missing observations or failed checks never imply an app is up to date.
