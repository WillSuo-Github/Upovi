# Checks, manual installation and release channels

Prepared for local build `202611040009`; this work does not publish a release.

## User-initiated installation only

Upovi never starts a new application update installation from startup, a timer, a notification or a saved per-app permission. The unattended installation implementation, settings, per-app grants, automatic history view and diagnostic CLI command have been removed. Previously saved `unattendedUpdatesV1` data is discarded when preferences are loaded, without restoring or running those jobs.

Startup and optional scheduled checks may discover newer releases and send reminders. They never download application payloads or start installation. Users choose Update or Update All and confirm the selected plan before installation. A manually started operation can complete or recover its existing transaction; it does not authorize a later update. These rules apply to Store apps, direct-distribution apps and global tools.

Upovi's Sparkle self-updater sets `SUAllowsAutomaticUpdates` and `SUAutomaticallyUpdate` to false and clears automatic download preferences before starting the updater. Optional automatic self-update checks can offer a release, but installation requires user action.

The single-app and batch installation paths retain their existing source, signature, identity, administrator-authorization and recovery checks. Beta remains a version-selection preference, never installation consent.

## Ignored updates in the sidebar

The Ignored sidebar section replaces the library's old Ignored filter. It includes installed apps with permanent update-reminder exclusions and apps with saved skipped-version rules, counting each installation once even when both rules apply. Saved skips remain visible before a fresh source check and after a newer release supersedes a skipped one; skipping one version does not suppress later releases.

Permanent exclusions and skipped versions have separate restore actions. Restoring one preserves the other and any snooze; it never starts downloading or installation. Version restoration is scoped to the exact bundle ID, distribution channel and developer identity. Search filters the visible rows without changing the sidebar total. Snoozed-only updates remain in the Updates page's reminder section.

See [local sidebar acceptance](evidence/ignored-sidebar-202611040009.json).

## Stable and Beta selection

Each non-Store app has a Release Channel picker in its detail view. Stable is the default. Beta includes supported prereleases as well as stable releases, choosing the newest comparable version; it never requests a downgrade. Change the channel and check again before installing. A Beta version is identified in update lists, review and confirmation views, including releases whose numeric version string lacks a Beta suffix.

Supported adapters:

- Sparkle: stable/unlabelled entries plus explicitly labelled alpha, beta, preview and RC entries when opted in. Unknown channels remain excluded.
- GitHub: the stable latest endpoint by default; with Beta selected, a bounded list of the 50 recent releases, excluding drafts, uncomparable tags and conflicting duplicate versions.
- Electron: public generic `latest-mac.yml` / `beta-mac.yml` and matching public GitHub release manifests. A Beta-only generic manifest can be used after a missing stable manifest. Archive hashes, ambiguity checks, staging restrictions, minimum-system requirements and manifest-signature restrictions remain enforced.
- Homebrew: supported comparable prerelease version formats require explicit Beta selection. Reviewed source-to-payload aliases are applied before classifying a release; a vendor's numeric build suffix is not blindly stripped globally.

Supported version comparisons include common alpha/beta/preview/RC and numeric prerelease revisions. Dedicated Nightly/Canary installations, unknown version formats, TestFlight, provider-specific channels and cross-bundle migrations are not inferred. A source which does not publish a supported Beta channel may continue to offer a stable release. Package payload identity, developer signature, architecture, target version/build and Gatekeeper requirements are unchanged. Opting into Beta does not bypass a source rollout restriction or permit an arbitrary package version.

## Store checks through mas

Local build `202611040007` removes Upovi's separate native refresh/cache APIs. Inventory and detection now use the bundled mas executable (`list`, `lookup`, and ordinary `outdated`); downloads and installation continue through that same executable. Upovi retains identity, compatibility, authorization and post-installation validation. Store installation starts only after user confirmation.

Background checks do not use mas's accurate download-and-cancel probe. Public catalog metadata can be delayed and does not prove ownership or an account-specific offer. Installation may require native account or administrator authentication.

The earlier Developer ID signed native probe on macOS 27.2 was rejected with `ASDErrorDomain` code `505` ("Not entitled for this service."). No successful native query was observed. That removed implementation's results remain in [historical local evidence](evidence/automatic-updates-202611040006.json); they do not describe the current mas detection path.
