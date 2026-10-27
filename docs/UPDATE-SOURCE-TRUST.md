# Update source and download trust

`ApplicationSourceCatalog.swift` is the local registry for exact bundle ID to Cask/GitHub mappings, reviewed download origins and exceptional packaging identities. Applications with an unambiguous identity in live Cask metadata need no additional mapping. Versions, download URLs and archive proofs normally come from live appcasts, Homebrew or GitHub. The registry ships with Upovi; a separate mapping server is not required.

## Maintenance

- Add an identity exception only after confirming the official product and exact bundle ID. Never match an application by display name alone.
- Add a signature-only download rule only after verifying the official origin, path scope and Developer ID Team ID. Unreviewed missing or changed installed developer identity stays manual; the narrowly pinned legacy Mos migration is documented separately in `docs/MOS-LEGACY-MIGRATION.md`.
- A packaging identity exception must bind the exact source version and official URL to the actual signed bundle version and build. Never strip arbitrary patch components or accept a mismatched version generically.
- Prefer an existing archive proof. A malformed or failing checksum/signature cannot fall back to developer-only validation.
- Community reports never authorize downloading or installing an update.

## Verification paths

An archive with a source SHA-256 or Sparkle Ed25519 signature follows the existing archive verification path, followed by application identity/version, nested signatures, architecture and Gatekeeper checks.

A reviewed official ZIP/DMG without an archive proof is downloaded for inspection. The installed application must satisfy an Apple-anchored Developer ID requirement. After bounded extraction, the incoming application must have the same bundle identity, the expected Developer ID, the exact selected version/build, valid nested code and a compatible executable, and pass Gatekeeper. The Developer ID requirement is checked again during the replacement transaction. PKG files remain ineligible for this fallback.

Signature-only transfers are recorded as downloaded and awaiting application verification. They become verified only after the full payload checks pass. They are not stored as verified archive cache entries. Interrupted verification requires a fresh check after restart. SHA-256 values calculated locally for audit are not presented as independent source proofs.

An appcast candidate with no download may use an unambiguous download from another checked source for the same version. The original candidate's build requirement is retained and enforced against the downloaded bundle. Conflicting versions, explicit builds and ambiguous downloads remain ineligible for supplementation.

## Current reviewed cases

- Typora: exact `abnerworks.Typora` to `typora` mapping. Live Cask metadata supplies the official DMG and SHA-256; this can fill the missing appcast download.
- iStat Menus: exact official CDN/path and Team ID `Y93TK974AT` permit signature-only inspection of direct application archives. The official `iStatMenus7.50.1.zip` contains bundle version `7.50`, build `2356`; this one packaging identity is explicit. Installation and subsequent checks use the actual bundle version/build, preventing a repeated false update.

## Acceptance

See `docs/evidence/update-source-trust-202610270002.json` for observed results. Tests passed: 189 Xcode tests and 8 release-metadata tests. The native development bundle built and passed nested code-signature verification. The signed and notarized build `202610270002` and its signed public latest feed are published; see `docs/evidence/0.4.10-build-202610270002.json` for CI, notarization and public-byte verification.

Real official packages were installed into isolated copies under `.local/update-source-acceptance-202610270002/Applications`:

- Typora `1.14.9 (7785)` to `1.14.15 (7789)`, fresh source check reported current, then restored to `1.14.9 (7785)`.
- iStat Menus `7.30 (2282)` to `7.50 (2356)`, fresh source check reported current, then restored to `7.30 (2282)`.

Both paths checked payload identity, Developer ID, Gatekeeper, actual installed bundle version and retained backups. Normal application copies in `/Applications` were not replaced. No background components, drivers or installer scripts were installed or tested.

Typora's upgraded executable was observed running from macOS App Translocation and matched the upgraded copy's executable SHA-256. Computer Use/AppleEvent window reads timed out, so first-launch UI acceptance is **not passed**. Only that verified test process was stopped before restoring the isolated copy.

To repeat with official signed old app copies already under a private acceptance root:

```sh
python3 script/acceptance/build_source_installation.py --output "$PWD/.local/source-acceptance"
.local/source-acceptance/source-installation --root "$PWD/.local/source-acceptance" --app "$PWD/.local/source-acceptance/Applications/Typora.app"
.local/source-acceptance/source-installation --root "$PWD/.local/source-acceptance" --app "$PWD/.local/source-acceptance/Applications/Typora.app" --restore-only
```

Main application replacement is the supported scope. A vendor may ask the user to update additional components on first launch; Upovi neither assumes nor reports completion of those components.
