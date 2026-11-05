# Source coverage and maintenance

Large-scale validation has a separate [compatibility lab](COMPATIBILITY-LAB.md). Its popularity-ranked inventory, production-parser metadata audit, signed-payload inspection, and real isolated upgrade/restore passes are counted separately. Catalog rows and unit tests must never be presented as thousands of verified upgrades. The first real cohort produced reviewed NetNewsWire, CC Switch and kitty mappings; DB Browser for SQLite's proposal was withheld after a staging filename incompatibility reproduced on its official package.

This describes the source changes prepared after build `202611040002`. They do not establish parity with another product, and no new release is published by preparing them.

## Electron sources

Upovi reads `Contents/Resources/app-update.yml` from the installed bundle. It supports explicit HTTPS generic providers and public GitHub stable releases, using `latest-mac.yml`. GitHub releases without a manifest may use their independently hashed native release archive. Files must remain inside the installed bundle; credentials, custom headers, private providers and non-stable channels are not inferred.

The bounded parser supports electron-builder's scalar fields and file list, including legacy path/SHA-512 metadata. Duplicate fields, YAML aliases/tags/arbitrary nesting and oversized input are rejected. Archive selection uses the host architecture and requires a unique DMG or ZIP with a valid source SHA-512. Ambiguous or unproven downloads remain manual. Checksums are rechecked after downloading; installed bundle identity, developer signature, target version, architecture and Gatekeeper checks still apply.

Special unsupported channels, required manifest signatures, staged rollouts and incompatible minimum kernel versions stay with the application's own updater. A staging restriction cannot be bypassed by a second source. Placeholder `.invalid` sources are manual rather than network failures. Supported Beta discovery is explicitly opt-in; signed Electron manifest verification is not implemented. See [automatic updates and channels](AUTOMATIC-UPDATES-AND-CHANNELS.md).

## Steam client detection

Steam's `CFBundleShortVersionString` / build `6.1` identifies its bootstrapper. It must not be compared with only the first component of a Homebrew cask version to declare the client current. Upovi reads the last client launch version from Steam's local console log, requires a matching installed package manifest and file list, and checks that the native client binary has not changed since that launch. Downloaded manifests alone are insufficient. Local metadata reads are bounded and remain within the Steam data directory.

For a corroborated stable client, Upovi compares that build with Valve's HTTPS `steam_client_osx` manifest. A newer build appears as an official-channel update, with actual client build numbers in the UI. Steam installs its own client updates; Upovi never replaces the Steam bundle or downloads its update. Unknown local evidence, a beta channel or a changed client requires checking in Steam and is not reported as current. A remote manifest failure remains an explicit failed check.

## Incomplete checks and GitHub throttling

The Updates page shows incomplete-check counts and individual source failures even when other updates are available. Last-known official version evidence is retained for at most 24 hours, scoped to the unchanged application identity, installed version and configured source/channel. Retained candidates are visibly marked for revalidation, retain the current failed check and the earlier confirmation time, lose their download descriptor, and cannot trigger downloads, installations or new-update notifications. A successful current result clears the previous update. No fresh evidence is fabricated when there has never been a successful check.

GitHub API metadata requests are serialized per origin. A successful authoritative appcast avoids a redundant GitHub release request unless a newer offer needs independent download proof. Metadata uses conditional validators; this does not make unauthenticated requests exempt from GitHub's quota. Explicit throttling honors the server's retry/reset time, including across app restarts through a private bounded cooldown record. Manual refresh does not bypass that cooldown. No developer account token or embedded credential is used.

When the stable GitHub release API is explicitly rate limited, Upovi can read the same repository's official `/releases/latest` page as a separate version-only source. Its bounded document head must identify one canonical stable release in that repository. Beta channels and ordinary HTTP 403 denials do not use this fallback. The API failure and retry time remain visible; the page supplies no invented archive, checksum or installation permission. If that page also fails, previously confirmed evidence may remain marked for revalidation. Shared-IP quotas and upstream availability cannot be eliminated by the app.

## Electron recovery under GitHub throttling

For an installed Electron GitHub provider, an explicitly rate-limited stable API can first confirm the exact stable tag from the official latest-release page, then read that tag's standard `latest-mac.yml`. Only the actual manifest can supply SHA-512 integrity data. Its version must match the confirmed release; duplicate/ambiguous/missing proofs remain manual. Explicit staging, required signatures, unsupported system requirements and cancellation still stop the route. Beta and ordinary API denials do not acquire this fallback.

Artifact selection prefers an explicit native architecture before choosing DMG versus ZIP, so a manifest containing both an unlabelled package and a distinct arm64 package does not become spuriously ambiguous on Apple Silicon. Multiple equally suitable packages still remain manual. The API failure and retry deadline remain visible even when a separately verified manifest supplies a usable download. Developer identity, payload version/architecture, sealed signatures and Gatekeeper must still pass after download; metadata eligibility is not installation acceptance.

A live read-only inspection of WowUp-CF 2.25.4 on 2026-11-05 found valid official SHA-512 proofs and matching Developer ID `L8KCUHBSU7` for both arm64 formats. However, both contain code directory hash `006ea879a127e9dafcccd8638fe3cadafe35585d`, which Gatekeeper rejected as `Unnotarized Developer ID`; Apple ticket lookup returned `Record not found`. The production installer correctly stopped before installing the isolated copy. The source/selection fixes therefore do **not** establish working automatic installation of that specific upstream release. No Gatekeeper, quarantine or signature requirement was bypassed. Normal installed applications were unchanged.

## Reviewed identities

`Resources/ReviewedSources.json` records the exact bundle ID, application filename, public cask token, official homepage and review date. `script/review_source_catalog.py` validates it and generates the compiled `ReviewedSourceCatalog.swift`. The mappings ship inside the signed app; remote catalog data cannot add identities or change installer trust rules.

```sh
python3 script/review_source_catalog.py --write
python3 script/review_source_catalog.py --live
```

The live check fetches individual public Homebrew cask records, verifies an enabled token, app artifact and bundle-identity reference, and reports source versions. It does not scan or upload a local app inventory. Metadata matching is not downloaded-payload validation. Additions still require human source/identity review; there is no remote signed catalog or unattended catalog writer.

`.github/workflows/source-catalog.yml` runs the same read-only check for relevant changes, manually, and daily at 03:23 Asia/Shanghai. It requires the workflow on the remote default branch and GitHub Actions enabled; preparing the local file does not activate it. Its token has only repository read permission, and it cannot rewrite mappings or publish releases. Scheduled checks validate the reviewed additions, not every entry in Homebrew or every remote archive.

The initial reviewed additions are Motrix, Sketch, Hoppscotch, MacSymbolicator, LocalSend and Tor Browser. Motrix 1.x has an explicitly reviewed dead-feed exception; later versions can use their own Electron source. Uncomparable source versions remain manual instead of weakening version comparison globally.

The signed arm64 Hoppscotch `v26.10.0-0` payload was reviewed separately: its short version and build are both `26.10.0`, and the publisher marks the release stable. That exact source version, download URL and installed developer identity have a payload alias. A future version or another architecture is not inferred. The live catalog check fails when this pinned source version changes, requiring another payload review.

## Store availability

See [App Store support](APP-STORE-UPDATES.md). Inventory, ordinary update detection and product metadata come from the bundled mas tool. Exact installed identity and compatible Mac metadata are validated before a mas-reported candidate enters update counts. Account-specific availability is decided by Apple during installation. Missing, failed or conflicting results stay unconfirmed. Upovi no longer queries native update caches or performs separate regional catalog recovery; mas-unavailable regional products require App Store confirmation.

## Local measurement

`UpoviPeer check-sources --summary-file <path> --details-file <private-path>` reports status counts, applications with a successfully checked version source, candidate counts and candidates eligible for the existing verification path. `--store-bridge <signed UpoviStoreBridge>` enables Store checks through that mas executable; no sibling native status helper is queried. Without a bundled Store bridge, Store coverage is unavailable.

Detailed results contain local paths and app names and are written with mode `0600`; keep them private. Compare identical path/bundle identities and report inventory changes separately. An eligible candidate is not proof that downloading, installation or first launch succeeded. A same-Mac Floodtide comparison has not been performed.
