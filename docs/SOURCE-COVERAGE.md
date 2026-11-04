# Source coverage and maintenance

This describes the source changes prepared after build `202611040002`. They do not establish parity with another product, and no new release is published by preparing them.

## Electron sources

Upovi reads `Contents/Resources/app-update.yml` from the installed bundle. It supports explicit HTTPS generic providers and public GitHub stable releases, using `latest-mac.yml`. GitHub releases without a manifest may use their independently hashed native release archive. Files must remain inside the installed bundle; credentials, custom headers, private providers and non-stable channels are not inferred.

The bounded parser supports electron-builder's scalar fields and file list, including legacy path/SHA-512 metadata. Duplicate fields, YAML aliases/tags/arbitrary nesting and oversized input are rejected. Archive selection uses the host architecture and requires a unique DMG or ZIP with a valid source SHA-512. Ambiguous or unproven downloads remain manual. Checksums are rechecked after downloading; installed bundle identity, developer signature, target version, architecture and Gatekeeper checks still apply.

Special channels, required manifest signatures, staged rollouts and incompatible minimum kernel versions stay with the application's own updater. A staging restriction cannot be bypassed by a second source. Placeholder `.invalid` sources are manual rather than network failures. Beta channel discovery and signed Electron manifest verification are not implemented.

## Reviewed identities

`Resources/ReviewedSources.json` records the exact bundle ID, application filename, public cask token, official homepage and review date. `script/review_source_catalog.py` validates it and generates the compiled `ReviewedSourceCatalog.swift`. The mappings ship inside the signed app; remote catalog data cannot add identities or change installer trust rules.

```sh
python3 script/review_source_catalog.py --write
python3 script/review_source_catalog.py --live
```

The live check fetches individual public Homebrew cask records, verifies an enabled token, app artifact and bundle-identity reference, and reports source versions. It does not scan or upload a local app inventory. Metadata matching is not downloaded-payload validation. Additions still require human source/identity review; there is no remote signed catalog or unattended catalog writer.

`.github/workflows/source-catalog.yml` runs the same read-only check for relevant changes, manually, and daily at 03:23 Asia/Shanghai. It requires the workflow on the remote default branch and GitHub Actions enabled; preparing the local file does not activate it. Its token has only repository read permission, and it cannot rewrite mappings or publish releases. Scheduled checks validate the reviewed additions, not every entry in Homebrew or every remote archive.

The initial reviewed additions are Motrix, Sketch, Hoppscotch, MacSymbolicator, LocalSend and Tor Browser. Motrix 1.x has an explicitly reviewed dead-feed exception; later versions can use their own Electron source. Uncomparable source versions remain manual instead of weakening version comparison globally.

## Store availability

See [App Store support](APP-STORE-UPDATES.md). Public version lookup and the native cached offer are separate evidence. Only exact matching positive offers enter automatic update counts; missing evidence stays manual. Explicit check-and-update remains available for supported identities. This does not refresh the native cache or find native-only/build-only offers.

## Local measurement

`UpoviPeer check-sources --summary-file <path> --details-file <private-path>` reports status counts, applications with a successfully checked version source, candidate counts and candidates eligible for the existing verification path. `--store-bridge <signed UpoviStoreBridge>` enables the complete Store checks using its sibling status helper. Without a bundled Store bridge, Store coverage is unavailable.

Detailed results contain local paths and app names and are written with mode `0600`; keep them private. Compare identical path/bundle identities and report inventory changes separately. An eligible candidate is not proof that downloading, installation or first launch succeeded. A same-Mac Floodtide comparison has not been performed.
