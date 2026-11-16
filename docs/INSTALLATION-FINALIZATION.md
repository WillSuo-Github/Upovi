# Verified application installation finalization

## Problem

An application copied into `/Applications` can retain download quarantine and launch from a read-only `AppTranslocation` mount. Sparkle then refuses to update it even though its original location is `/Applications`. A successful file replacement and valid code signature alone do not establish normal installed-app launch behavior.

## Policy and implementation

- `UpdateInstaller.prepare` keeps downloaded/prepared bundles quarantined in a private workspace. Archive integrity, selected version, developer identity, code signatures, executable compatibility and distribution trust checks remain mandatory.
- A user-confirmed installation calls `ApplicationInstallation.finalize`. It matches the expected bundle ID, Team ID, version and build, validates the installation signature, checks distribution trust, and revalidates identity before changing metadata. Third-party applications require the existing Developer ID signature and fresh Gatekeeper acceptance. The narrowly reviewed Apple Software Signing route below handles a specific bundle-format incompatibility.
- Only `com.apple.quarantine` inside that selected bundle is removed. Descriptor-relative traversal skips symbolic links and rejects external hard links, cross-volume entries and unsupported file types. Provenance, Finder metadata, permissions and application data remain untouched. The bundle root is cleared last; failures are reported instead of silently declaring installation complete.
- Ordinary installs finalize the staged replacement before copying and activating it, then check that activation did not reintroduce quarantine. The administrator helper finalizes its protected incoming bundle before activation; PKG installations finalize the verified resulting application. Backups and rollback records are retained.
- No system security setting is disabled. Untrusted, rejected, changed or App Store applications cannot use this finalizer.
- `ApplicationRunningLocation` maps an existing translocated process to the exact original app path using the read-only nullfs mount's source. Bulk close confirmation, ordinary quit/wait logic, backup cleanup checks and the Store helper's running-app guard use this mapping. A matching file name or bundle ID alone never authorizes closing another installation.

The scoped quarantine handling follows the purpose of Sparkle's [`SUPlainInstaller`](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Autoupdate/SUPlainInstaller.m) and [`SUFileManager`](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SUFileManager.m). Incomplete finalization remains a failure.

## Reviewed Apple Software Signing releases

The official Icon Composer 1.1 (59) and 1.2 (76) bundles omit `CFBundlePackageType`. Their signatures validate, but `spctl --assess --type execute` returns exit 3 with exactly `rejected (the code is valid but does not seem to be an app)`. Their Apple **Software Signing** certificate is also distinct from third-party Developer ID. Retrying App Management authorization does not repair either incompatibility.

`ReviewedAppleSoftware` binds these two releases to the exact bundle ID, signed Team ID, version, build and universal executable SHA-256. It additionally requires the strict `anchor apple` signature and identifier, every architecture, nested code and sealed resources, with certificate revocation checks enabled. A hash or displayed Team ID alone never suffices. The incoming app remains subject to archive proof, version and executable compatibility checks. Downloads lacking archive proof continue to require Developer ID and cannot use this route.

The alternative assessment route is considered only for the exact exit-3/not-app result, including the assessed path and no additional output. Other failures, revocation results, timeouts, cancellations, altered resources, ad hoc signatures and unreviewed versions remain failures. No Apple bundle is modified or re-signed. Finalization, already-installed detection and backup maintenance share the installation-signature check.

Diagnostics record `event=reviewedAppleVerified verdict=notAppLike trust=reviewedAppleSoftware`, never a fabricated Gatekeeper approval. Original tool output and paths are excluded. Official source URLs, artifact hashes and acceptance results are recorded in `docs/evidence/icon-composer-apple-trust-20261116.json`.

## Validation on 2026-10-30

- 237 local Swift tests passed, including rejection before quarantine removal, identity changes during assessment, unsigned applications, nested metadata preservation, symlink confinement, hard-link rejection and exact original-mount matching for translocated processes.
- An isolated copy of the official signed GitPico `20261028171943` was updated to `20261030182540` through the production prepare/install pipeline using an offline archive of the signed payload. Prepared quarantine remained present; installed quarantine was absent; the Developer ID signature stayed valid and the old bundle was retained. Isolated application copies and the archive were removed after validation.
- The existing `/Applications/GitPico.app` passed the same finalizer, retaining its version and signed contents. Its repaired process launched at `/Applications/GitPico.app/Contents/MacOS/GitPico`, and native Check for Updates displayed the normal up-to-date result instead of the translocation error.
- The signed Upovi app and administrator helper build successfully. This acceptance did not execute a new administrator/PKG installation or change other running applications.

Local evidence is retained under `.local/quarantine-acceptance` and `.local/quarantine-final-tests.log`; it is not published with the source.
