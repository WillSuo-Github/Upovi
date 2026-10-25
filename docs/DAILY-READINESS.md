# Upovi 0.4.0 daily-use readiness

Date: 2026-10-25, Asia/Shanghai. P2P mechanism expansion is deferred by the owner. The linked public preview remains 0.3.2; this work is a development candidate.

## Implemented

- Exact-identity source mappings for additional common apps, conservative product disambiguation when vendors reuse bundle identifiers, Intel/OS catalog variations and recognized packaging-version forms. Unknown formats do not become successful current checks.
- Source filters for unadapted and incomplete checks. CLI `--details-file` writes private per-app diagnostics; raw inventories stay ignored.
- System-backed login-item toggle with requires-approval/error states and refresh when returning from System Settings. No registration occurs automatically.
- Retained-copy sizes, explicit Trash cleanup for completed transactions, tracked displaced apps after new restores, and refusal to clean interrupted/changed/linked recovery material.
- Sparkle 2.10.0 integration for Upovi itself, signed feeds and archives, automatic checks initially off, settings/menu entry points, and relaunch deferral during third-party installation. Release metadata has one source in `Resources/Release.json`.
- Source checks pause offline, become eligible after reconnect/wake independently of P2P, and recover from wall-clock rollback.
- Upovi-managed administrator installation and main-app recovery following [the separate design](ADMINISTRATOR-INSTALLATION.md). A protected, verified helper performs root transactions; inspectable direct PKGs require matching developer and payload identities. PKG side effects outside the main app are not rolled back. No persistent daemon is installed.
- Universal helper/framework packaging, nested signatures, signed-feed generation and a release verifier. The verifier has an explicit notarization-required mode; ordinary verification does not claim notarization.
- Source-only long-observation mode, bounded per-sample traffic snapshots and visible/windowless sample counts. The observer never prevents sleep, changes settings, restarts the app or automatically accepts a completed timer.

## Evidence and boundaries

The local source comparison used the same 71 applications, including 23 App Store apps and one synthetic fixture. Before: 27 supported direct-source checks, 21 unsupported. After source adaptation: 40 supported, 8 unsupported, zero failed/partial in that run. Seven remaining real applications lack an adapted reliable public source; one unsupported entry is synthetic. This is a one-machine sample, not universal coverage or an install-success rate. Raw details remain in `.local/daily-readiness/`.

The local suite has 73 passing tests. New cases cover product ambiguity, platform variants, packaging versions, schedules, backup cleanup, administrator plan restrictions, first package-signer identity, shell injection, AppleScript compilation without execution, recovery identity/staleness preservation of failed-command diagnostics and compilation of the real code-signing requirement and physical temporary-path resolution. Isolated automatic/public-protocol and legacy private-exchange regressions are separate checks; public P2P load testing is not part of this iteration.

Native login-item acceptance on the signed development app observed 0 → 1 → 0 with no registration error; it was returned to disabled. Native confirmed cleanup of an isolated synthetic backup passed: cancellation retained the backup, confirmed Trash cleanup updated the journal, and the live synthetic app remained at 2.0. The temporary test journal was removed. Source-only observation uses P2P disabled, sharing disabled, notifications disabled and the existing fifteen-minute source schedule. The fresh 24-hour result must be read from its evidence before making any long-run reliability claim.

Actual administrator authorization and the production protected helper replaced an isolated signed Rectangle copy from 2.0.3 build 110 to 2.0.4 build 111, then restored 2.0.3 build 110. Both resulting bundles passed signature verification. The fixture was moved out of /Applications afterward. This exercises the production bootstrap/helper through a diagnostic caller, not the native installation button. Early attempts were rejected before replacement because Foundation shortened the private temporary-directory alias; physical realpath resolution and a regression test repaired that failure.

A real official PKG passed archive SHA-256, installed-application/developer Team ID matching, Gatekeeper installer assessment, one matching app payload, nested signature and native executable checks. The PKG was expanded for inspection only; no package scripts or installer operation were executed.

Still requiring independent acceptance:

- A complete uninterrupted 24-hour run on the final candidate, actual interface switches, physical sleep/wake and direct energy measurement.
- Native administrator install-button acceptance, actual PKG script execution, interrupted privileged transactions and reboot cases. The successful authorized app replacement/recovery above does not establish those cases. Protected administrator backups are retained; no root-backup pruning is provided in this candidate.
- Publishing the new ZIP/feed together and a genuine old-to-new Sparkle update. Local feed/archive signature verification does not establish a working public feed or an end-to-end replacement.
- Apple notarization remains deferred under the owner's earlier distribution decision. The packaging path supports submission/stapling; no new submission is implied.
- Current-source CI on other macOS/CPU targets. Previous-version CI is not acceptance of the new helper or framework integration.

Aggregate results and artifact identities are recorded in `docs/evidence/0.4.0-daily-readiness.json` after final packaging. Do not attach the raw local inventories or settings to a public issue.
