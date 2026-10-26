# Download center and remaining acceptance, 0.4.6

## Download tasks

The sidebar's Download tasks section (Command-4) shows current transfers and recent results for ZIP, DMG and PKG preparation. Pause cancels only the current network transfer and keeps its partial cache; Continue resumes the existing authorized operation. A disconnected transfer waits for network availability and continues automatically after reconnection. Transient connection failures and selected HTTP 408/429/5xx responses receive at most three bounded retries. TLS, authorization and integrity failures do not automatically retry. Stop-all still stops a batch; cancel-this-download only cancels the current artifact operation.

All attempts use the same strong-validator range cache and mandatory final integrity checks. Verification completion means the archive is verified; bundle/package validation and individual or batch installation consent still apply. Pausing cannot interrupt an atomic application replacement. Late callbacks from an earlier cancelled transfer cannot overwrite a newer control generation.

Recent task summaries survive restart in a private bounded journal. They store application identity, target version, progress, phase and classified issues, never download URLs, integrity proofs or installation consent. Active records become interrupted on cold launch and never restart automatically. Explicit retry refreshes apps and sources, checks the original bundle/developer/path identity, applies ignore/skip/snooze policy and prepares only the fresh eligible candidate. The existing installation confirmation is required. Corrupt or linked history is preserved and its write failure is visible; it does not authorize installation. Existing caller output files cannot be overwritten.

The center retains at most 50 summaries with no more than ten concurrent core callers; the application continues to serialize installation workflows. Progress persistence is throttled. Diagnostic reports include allowlisted download states while preserving their existing identifier/URL redaction rules.

## Actual administrator and PKG acceptance

A disposable Tart clone of the existing macOS Tahoe base image was used. The host mounted only a dedicated read-only acceptance directory; the VM had its own /Applications, root journals and package side effects. No daily host application was replaced. Automatic Tart cache pruning was disabled when cloning.

Official Zoom packages 7.2.1.88329 and 7.2.2.88465 matched the [official Homebrew cask history](https://github.com/Homebrew/homebrew-cask/commits/master/Casks/z/zoom.rb) and vendor CDN checksums. The old package seeded the VM. The signed production UpoviInstaller helper then verified and executed the real new PKG, retained its protected backup and installer log, and restored the original signed app: 7.2.1 → 7.2.2 → 7.2.1. Both installed and restored signatures were valid. This is actual package execution, not payload expansion alone.

A second protected transaction was forcibly terminated at its durable backedUp checkpoint. The entire guest OS rebooted. The root receipt and verified original backup survived, and a fresh production-helper restore succeeded with the original version/signature. This exercises an actual helper process death and guest kernel reboot at one named checkpoint; it does not prove every possible interruption point or rollback package scripts, services, drivers or app-data migrations. The normal host authorization bootstrap had separate earlier acceptance; the disposable guest uses its explicit passwordless sudo for protected-helper execution. `script/acceptance/privileged_vm.swift` refuses to run without a disposable-VM marker.

## Checks and release state

149 local tests passed (134 core, 15 store), including control races, pause/resume, cancel while paused, parent cancellation, reconnect, bounded retries, nonretryable validation, private history, corrupt/existing-file preservation, and fresh-source retry identity/policy checks. Native synthetic acceptance used the actual coordinator/store/views with a deliberately injected slow transfer to verify pause, offline wait, reconnect continuation, cancel, cold-start interruption and refusal of stale consent. This UI acceptance does not claim a real server transfer; real HTTPS resume was separately accepted in 0.4.4 and archive/integrity regressions remain covered.

[Version-specific evidence](evidence/0.4.6-completion.json) records CI, signed artifact, public feed and genuine Sparkle old-to-new replacement results as they finish. The newest-candidate 24-hour observation must accumulate its own real elapsed time. Physical sleep/wake, actual network changes and power sampling remain separate measured checks. Previous-version observation duration is never transferred. Apple notarization retains the owner's deferred status; a signed preview is not a notarized release.
