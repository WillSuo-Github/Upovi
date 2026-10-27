# Mos 3.5.0 developer migration

The official Mos 3.5.0 universal DMG contains bundle `com.caldis.Mos`, version `3.5.0`, build `2024.01.11`. Its ad hoc signature passes strict nested/all-architecture validation but has no developer Team ID. The previous same-Team policy therefore placed this intact official application in the manual-update group.

## Reviewed identity

`ApplicationSourceCatalog.legacyMigrations` contains one exact exception for that bundle/version/build with no Team ID. The full universal executable SHA-256 is pinned as `14e4f8367192273f8b95b8df90c63d471841a71bbc250500c648e78fc5709fe0`. Pinning the complete Mach-O also pins both embedded code directories. Strict code-signature validation binds the original Info.plist and sealed resources to those code directories. A changed resource fails validation; re-signing a changed app changes the executable fingerprint and also fails.

The fingerprint was reviewed from the [official old release](https://github.com/Caldis/Mos/releases/tag/3.5.0). The observed DMG hash in the evidence is an audit fingerprint, not an independent upstream archive proof. A display name, bundle ID and version string alone never authenticate the old app.

The installed Team ID remains absent in inventory and receipts. Only the expected **successor** developer is pinned to `N7Z52F27XK`. The incoming application must satisfy that Apple-anchored Developer ID requirement, the same bundle ID, the exact selected version/build, nested signatures, compatible architecture and Gatekeeper. Migration downloads still require a source archive proof. An exact `com.caldis.Mos` to `mos` Cask mapping provides another live source when GitHub API requests are rate limited.

## Replacement and recovery

The old signature and executable fingerprint are checked before download, immediately before replacement and on the retained backup. The ordinary transaction validates the new signed developer on both sides of the final rename. Recovery checks the pinned legacy backup and refuses unrelated or externally changed replacements. Backup cleanup understands both the legacy and signed identities. Administrator application plans use the same verification policy; the legacy exception cannot authorize PKG installation.

Individual confirmation explains that the old official files were verified and the update adopts the signed developer identity. First launch may require the user to confirm system permissions again. Upovi does not alter Accessibility/TCC permissions or bypass quarantine/Gatekeeper.

## Acceptance

All 195 local Xcode tests and 8 release-metadata tests passed. Real isolated official Mos copies completed `3.5.0 (2024.01.11)` to `4.2.1 (20260531.1)` installation, Developer ID/Gatekeeper checks and restoration to the pinned old version. A fresh Homebrew check produced no remaining update; GitHub API rate limiting remained an explicitly recorded partial check.

The real native Upovi views displayed one installable Mos update, its download/verify button and the legacy identity explanation. Actual install, installed history, restore confirmation and restored history passed. Filesystem metadata and the restored journal independently confirmed the old version. Modified-resource and re-signed modified-resource copies were rejected. Normal `/Applications/Mos.app` was not replaced; actual privileged execution and Accessibility grants were not performed.

See [machine-readable evidence](evidence/mos-legacy-migration-202610270003.json). Build `202610270003` and its signed public latest feed are published. All three macOS CI jobs, notarization, ticket stapling, public asset-byte comparison and extracted signature/Gatekeeper checks passed; see [release evidence](evidence/0.4.10-build-202610270003.json).

To repeat native acceptance with an official old copy:

```sh
python3 script/acceptance/build_bulk_fixture.py --mode mos --original /path/to/official/Mos.app --output "$PWD/.local/mos-acceptance"
open -n "$PWD/.local/mos-acceptance/UpoviMosAcceptance.app" --args --root "$PWD/.local/mos-acceptance"
```
