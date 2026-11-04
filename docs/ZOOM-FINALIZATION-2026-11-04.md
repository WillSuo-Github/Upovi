# Zoom installation result and post-install finalization — 2026-11-04

Pre-release acceptance for build `202611040012`, marketing version `0.4.10`. This extends the preceding upfront-authorization work. Distribution results are recorded separately in release evidence; this investigation did not replace the user's installed Upovi.

## Observed sequence

The host's system installer log records Zoom Workplace `7.2.5.90525` installed at 21:09:50 Asia/Shanghai, followed by normal installer completion at 21:09:52. Upovi's attempt recorded `Operation not permitted` at 21:09:56. The selected package SHA-256 was `4c26ebed8bd29ce258ac9dbe0f2b327fad0a0734246ea588339a2cc5fd10533e`.

Read-only inspection found the actual installed application at `7.2.5 (90525)`, build `7.2.5.90525`, with the expected Zoom Developer ID. Upovi's signature/Developer ID checks, its root quarantine-marker check and the macOS Gatekeeper assessment passed. A fresh run of the actual `UpdateChecker` returned `current`, and the selected-target check returned true. The separate `codesign --verify --deep --strict` command rejected existing FinderInfo metadata; that metadata was left untouched. No host application was reinstalled, launched, stripped of attributes or otherwise modified during this investigation.

The disappearing row was explained by two existing behaviors. Batch completion rescanned the installed version, which correctly no longer qualified as an available update. A due scheduled check then called `dismissBulkSummary`, removing the failed-batch row and its explanation. "No new version" was therefore being presented after an unresolved installation result.

## Changes

- Finalization now reads each entry's quarantine attribute before attempting removal. An absent attribute requires no write. The old unconditional `fremovexattr` returns EPERM on protected files even when the attribute is absent; a new regression reproduced the failure before the fix and passed afterwards. Actual quarantine that cannot be removed still fails, and protection flags/other metadata remain unchanged.
- A PKG installation whose selected application has been verified on disk now records its finalization checkpoint. If finalization fails, the root receipt and normal app retain `finalizationPending`, the installed application and a bounded error/domain/code. The UI describes an updated app with incomplete finalization; the batch remains unsuccessful. It is not silently changed to success based on version alone.
- Scheduled source checks retain failed-batch results. Explicit refresh may still clear the summary. A regression models the selected version already on disk, a current source check, no reinstallation, and the failed result remaining visible.

The old host receipt did not include a failing path/checkpoint, so the exact original entry that denied access is not established. The unnecessary-write defect is reproduced, and avoiding all quarantine mutations when none are present removes that failure condition. No historical receipt was rewritten as successful.

## Validation

- Full local test suite: 266 core and 58 app tests passed, zero failures.
- A new Developer ID signed Xcode development bundle and embedded helpers built and passed bundle signature verification on the host architecture.
- The exact cached package from the reported attempt was copied into the existing marked disposable VM. `script/acceptance/zoom_finalization_vm.swift` ran the production signed-helper bootstrap and batch-session path once using that VM's established passwordless sudo in place of the human authorization dialog.
- The actual vendor PKG updated the VM's official Zoom `7.2.1 (88329)` to `7.2.5 (90525)`. The helper returned `installed`, with no finalization failure; Developer ID and quarantine finalization checks passed.
- The production recovery path restored the VM's original Zoom version and valid signature. The test transaction was removed. VM fixtures and processes are cleaned up after evidence capture.

Not established: reproduction of the exact host privacy-policy denial on the same original file, a human-completed native authorization dialog for this build, GUI launch acceptance of the updated Zoom, Intel execution, notarization or public delivery. Vendor PKG system effects outside the main application are not rolled back by main-app recovery.

## Distribution follow-up

Build `202611040012` was published as the latest notarized universal release. Public archive/feed checks and acceptance boundaries are recorded in [release evidence](evidence/0.4.10-build-202611040012.json). The normal installed Upovi was not replaced by publication.
