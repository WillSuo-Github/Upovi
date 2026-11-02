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

## Build 202611020004: authoritative builds and reviewed Developer ID transfer

Sparkle's advertised `CFBundleVersion` now governs both eligibility and payload validation when the candidate explicitly declares that build authoritative. The incoming build must equal the selected build and be strictly newer than the installed build. Display-label differences do not bypass archive verification, bundle identity, signatures, architecture or Gatekeeper. Other sources retain exact version checks. Completion checks also use the authoritative build, so a payload with a differing display label is not offered again.

The official [PlayCover 4.0.0 prerelease](https://github.com/PlayCover/PlayCover/releases/tag/4.0.0-prerelease) advertises `4.0.0 / 1633` in its appcast but contains signed `3.1.0 / 1633`, as confirmed by [upstream issue 2246](https://github.com/PlayCover/PlayCover/issues/2246). With official `3.1.0 / 856` as an isolated anchor, archive signature, exact authoritative build and Developer ID validation passed. Gatekeeper rejected this downloaded release with `Unnotarized Developer ID`; production preparation stopped and the original remained unchanged. This is **not** a successful PlayCover installation. Gatekeeper failures now provide an explicit localized macOS security-check explanation. No security policy or quarantine bypass was added.

OpenClaw has one reviewed, one-way Team ID transfer for the exact `ai.openclaw.mac` identifier: `Y5PE65HELJ` to `FWJYW4S8P8`. The official [2026.3.1 ZIP](https://github.com/openclaw/openclaw/releases/tag/v2026.3.1) and [2026.10.9 DMG](https://github.com/openclaw/openclaw/releases/tag/v2026.10.9) were hash-verified and inspected; both retain the same Sparkle Ed25519 public key. The installed old bundle must independently pass Apple-anchored Developer ID verification before download; the new bundle must pass the successor requirement and Gatekeeper. Unknown teams, other bundle IDs, reverse transfers, App Store apps and PKG migration remain excluded. Original signatures, new signatures, recovery and backup cleanup track both sides. A production isolated upgrade from `2026.3.1 / 2026030190` to `2026.10.9 / 2610000990`, already-current recheck and restore all passed. Main-bundle replacement was tested, not first-launch behavior or auxiliary service/data migration.

The still earlier official `2026.2.15` has identifier `bot.molt.mac`. That identifier change is not an approved automatic bundle replacement: its available update remains visible with an official-installer migration explanation instead of entering a doomed automatic task.

The reporting Mac runs Upovi `202611020003`, but its installed app identities and pnpm environment were not read directly. The reproduced causes and tested paths do not establish remote installation success. See [acceptance evidence](evidence/source-errors-202611020004.json). The notarized universal build `202611020004` is now published; see [release evidence](evidence/0.4.10-build-202611020004.json).
