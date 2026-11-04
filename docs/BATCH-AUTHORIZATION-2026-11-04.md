# Upfront batch authorization and queue replenishment — 2026-11-04

Pre-release acceptance for build `202611040011`, marketing version `0.4.10`. The feature is also included in build `202611040012`. Distribution results are recorded separately in release evidence; the acceptance below used signed development bundles without replacing the user's installed application.

The previous batch gathered every privileged request after the full preparation queue had drained. A ready Store/PKG row could therefore say "Waiting for authorization" while an unrelated slow download continued. The shared display order also divided application downloads into contiguous runs separated by serial tool tasks, leaving available concurrency idle at a tool boundary.

A confirmed batch now authorizes before starting downloads or installs, when its selected items need privileges. The signed root helper retains a capability restricted to that batch's application identities, selected versions, operations and Store IDs. Downloads stay unprivileged. Ready typed installation requests are processed serially, and each result is delivered immediately. No password is stored, no persistent daemon is installed, and later requests cannot contain executable shell commands. Cancellation skips unstarted jobs; a committing installer completes. Batch completion, parent exit or a six-hour deadline ends the session. Downloads interrupted past this session lifetime require a new explicit update action.

The queue admits mixed rows using the configured width (default five, range one through eight). Tool updates remain serial. A busy tool never prevents a later application from taking a free slot. Privileged work proceeds separately from download/preparation admission.

## Validation

- Full local SwiftPM run: 262 core and 57 app tests passed, zero failures. New coverage checks upfront authorization, one authorization despite failed/slow sibling preflights, cancellation, five occupied mixed slots, replenishment before the first slow download finishes, one active tool, typed selection restrictions, and rejection of request links/devices/oversized input.
- Xcode Developer ID signed development bundle and embedded helpers built and passed deep/strict/all-architecture signature verification on the host architecture.
- The existing explicitly marked disposable Tart VM ran the production signed-helper bootstrap once using its established passwordless sudo in place of the human password dialog. Two isolated official Rectangle copies updated 2.0.3 → 2.0.4 through one root session; the second request arrived after the first completed. An unconfirmed version was rejected. Stop prevented a fourth selected item from installing. All target signatures remained valid; untouched targets remained 2.0.3; the session exited and removed its result directory. The acceptance runner cleans its isolated targets, transaction journals and temporary input directory.
- The reproducible VM-only runner is `script/acceptance/authorization_session.swift`. Inputs must be extracted onto the guest filesystem before running, preserving application symlinks. It refuses execution without the existing protected disposable-VM marker.

Not established by these checks: a new human-completed native password dialog, a real mixed App Store/PKG batch using this session, physical Intel runtime, notarization, public delivery, or the exact origin of every prompt reported by the user. Apple ID sign-in, privacy consent and vendor-owned installer interactions are outside the shared administrator authorization.

## Distribution follow-up

Build `202611040012` was published as the latest notarized universal release. Public archive/feed checks and acceptance boundaries are recorded in [release evidence](evidence/0.4.10-build-202611040012.json). The normal installed Upovi was not replaced by publication.
