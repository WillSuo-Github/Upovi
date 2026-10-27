# Security model and reporting

Upovi is an experimental update detector and globally controlled public observation network. Publisher signatures prove the signing key; they do not prove a real installation, an independent person, or an official release. Open rendezvous slots permit arbitrary writers and can be poisoned or crowded. Cached-key sampling, replica merging, rotation, and replay checks improve continuity but do not solve Sybil attacks or guaranteed discovery.

Community reports never contribute to the available-update count, available-updates list, notification payload or notification deduplication state. Matching an independently checked source version/build only annotates a report; the source result remains the sole update authority. Multiple publisher keys do not establish independent people, and cannot promote a report into a confirmed update. See [the trust policy](docs/COMMUNITY-TRUST.md) for exact matching and source-provenance boundaries.

Only official metadata adapters or a locally configured source can offer a download. Installation requires either a source archive SHA-256/Sparkle Ed25519 proof or a reviewed official-origin download rule. The latter is limited to direct ZIP/DMG app replacement and checks an Apple-anchored Developer ID on both the installed and incoming app. Both routes require matching bundle ID and developer Team ID, valid nested code signatures, the exact selected version/build, compatible executable architecture, and macOS Gatekeeper acceptance. Malformed or failing archive proofs never downgrade to the signature-only route. See `docs/UPDATE-SOURCE-TRUST.md` for the explicit rules. P2P observations never supply installation URLs.

ZIP extraction rejects absolute/parent paths, hard links, unsafe symlinks, writes through links, duplicate files, special devices, and bounded size/time violations. Conservative rejection may require using a vendor's own updater. DMGs are mounted read-only. PKG/script installers and elevation are not supported. Replacement retains the original application on the destination volume and journals progress before destructive renames.

For a vulnerability, use the repository's private vulnerability reporting when available. Do not include secrets or a real installed inventory in a public issue. A missing report, unreachable endpoint, or unsupported source is never proof that an application is current.

## Global participation defaults

A fresh 0.4.1 installation enables public discovery and sharing for all scanned apps through one Settings switch. The settings UI describes the public fields and IP visibility. Earlier app-specific consent migrates to off; existing explicit global choices persist. Corrupt/unreadable settings fail closed. Disabling the global switch cancels active synchronization and closes the UDP transport, but cannot recall already cached public records. See `docs/GLOBAL-P2P.md`.

## Reviewed legacy developer migration

Mos 3.5.0 (2024.01.11) has a valid ad hoc signature and no Team ID. Its sole reviewed migration pins the complete universal executable SHA-256 and requires strict validation of sealed resources and all architectures. The incoming app must have an Apple-anchored Developer ID for the explicitly pinned successor team, the same bundle ID, the selected version/build and Gatekeeper acceptance. Installed metadata alone never authenticates this migration. The old identity is rechecked during replacement and its backup is checked before restoration. Unreviewed missing or changed developer identities stay manual. This exception does not support PKG installation, bypass Gatekeeper or grant Accessibility permissions. See `docs/MOS-LEGACY-MIGRATION.md`.
