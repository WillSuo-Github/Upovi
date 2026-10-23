# Security model and reporting

Upovi is an experimental update detector and opt-in public observation network. Publisher signatures prove the signing key; they do not prove a real installation, an independent person, or an official release. Open rendezvous slots permit arbitrary writers and can be poisoned or crowded. Cached-key sampling, replica merging, rotation, and replay checks improve continuity but do not solve Sybil attacks or guaranteed discovery.

Community reports never contribute to the available-update count, available-updates list, notification payload or notification deduplication state. Matching an independently checked source version/build only annotates a report; the source result remains the sole update authority. Multiple publisher keys do not establish independent people, and cannot promote a report into a confirmed update. See [the trust policy](docs/COMMUNITY-TRUST.md) for exact matching and source-provenance boundaries.

Only official metadata adapters or a locally configured source can offer a download. Installation additionally requires an archive SHA-256 or installed Sparkle Ed25519 key, matching bundle ID and developer Team ID, a valid nested code signature, the selected version, compatible executable architecture, and macOS Gatekeeper acceptance. P2P observations never supply installation URLs.

ZIP extraction rejects absolute/parent paths, hard links, unsafe symlinks, writes through links, duplicate files, special devices, and bounded size/time violations. Conservative rejection may require using a vendor's own updater. DMGs are mounted read-only. PKG/script installers and elevation are not supported. Replacement retains the original application on the destination volume and journals progress before destructive renames.

For a vulnerability, use the repository's private vulnerability reporting when available. Do not include secrets or a real installed inventory in a public issue. A missing report, unreachable endpoint, or unsupported source is never proof that an application is current.
