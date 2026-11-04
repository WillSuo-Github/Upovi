# Unattended updates and release channels

Prepared for local build `202611040006`; this work does not publish a release.

## Unattended app updates

The master switch and every app permission start off. In Settings → Automatic Updates, authorize individual applications and enable the master switch. Permission is bound to the exact installed path, bundle ID, developer Team ID and selected release channel. Changing channels revokes automatic permission. Restoring a retained app through Upovi also revokes its automatic permission, so a rollback is not immediately undone.

While Upovi is running, the normal check interval controls scheduled work; startup can also run previously authorized updates after a fresh inventory/source check. Sleep and quitting pause the schedule. A normal manual refresh does not start installation; Check and Run Authorized Updates explicitly runs the authorized policy.

Admission requires a complete successful source result, the latest eligible candidate, a source archive proof and a ZIP/DMG app replacement. Ignored apps, skipped versions and snoozed reminders stay excluded. Running apps, unwritable destinations, packages, Store apps, global tools, Upovi itself and reviewed identity/developer migrations stay manual. No unattended path invokes administrator authorization, Store installation, package scripts, app relaunch or forced quit.

Sources are revalidated before processing the automatic queue and again when its metadata generation is five minutes old. Permission, channel, source candidate, running state and write access are checked again before commit. The installer checks running state again around final verification and at the original-bundle validation boundary, and checks cancellation before the rename transaction. Once that transaction starts, it finishes or recovers atomically even if Stop is pressed.

Each attempt is saved before preparation and again before commit. If history cannot be saved, installation does not start. Ordinary success/failure records are saved without opening a review sheet or an authorization flow. Failures, cancellations and unfinished attempts suppress automatic retry of the same target/channel for 24 hours; a running-state deferral can be reconsidered next cycle. Unfinished work is shown as interrupted after relaunch and is never resumed blindly. One app's failure does not prevent later eligible apps from being processed. The private settings file retains up to 500 app permissions/last attempts and 100 recent history records.

Previous main app bundles use the existing installation journal and recovery UI. These backups do not restore application data or other system changes. Automatic updates do not enable login launch or install a background daemon. System filesystem/privacy restrictions can still reject an operation; Upovi does not bypass them.

## Stable and Beta selection

Each non-Store app has a Release Channel picker in its detail view. Stable is the default. Beta includes supported prereleases as well as stable releases, choosing the newest comparable version; it never requests a downgrade. Change the channel and check again before installing. A Beta version is identified in update lists, review and confirmation views, including releases whose numeric version string lacks a Beta suffix.

Supported adapters:

- Sparkle: stable/unlabelled entries plus explicitly labelled alpha, beta, preview and RC entries when opted in. Unknown channels remain excluded.
- GitHub: the stable latest endpoint by default; with Beta selected, a bounded list of the 50 recent releases, excluding drafts, uncomparable tags and conflicting duplicate versions.
- Electron: public generic `latest-mac.yml` / `beta-mac.yml` and matching public GitHub release manifests. A Beta-only generic manifest can be used after a missing stable manifest. Archive hashes, ambiguity checks, staging restrictions, minimum-system requirements and manifest-signature restrictions remain enforced.
- Homebrew: supported comparable prerelease version formats require explicit Beta selection. Reviewed source-to-payload aliases are applied before classifying a release; a vendor's numeric build suffix is not blindly stripped globally.

Supported version comparisons include common alpha/beta/preview/RC and numeric prerelease revisions. Dedicated Nightly/Canary installations, unknown version formats, TestFlight, provider-specific channels and cross-bundle migrations are not inferred. A source which does not publish a supported Beta channel may continue to offer a stable release. Package payload identity, developer signature, architecture, target version/build and Gatekeeper requirements are unchanged. Opting into Beta does not bypass a source rollout restriction or permit an arbitrary package version.

## Native Store refresh

The coalesced Store snapshot now asks an unprivileged helper for a native read-only refresh. It validates runtime selectors and the system protocol's callback encoding before invoking AppStoreDaemon's background reload API. Calls are bounded; stale replies, access rejection, unknown version metadata, helper failures and timeouts remain unconfirmed. The helper does not invoke install, purchase, cancellation, automatic-update configuration or authorization APIs. No download-and-cancel probe is used.

On this Mac running macOS 27.2, the Developer ID signed native probe and final helper are rejected with `ASDErrorDomain` code `505` ("Not entitled for this service."). The legacy CommerceKit probe also returned no valid result. This is **not a successful native refresh**, and it does not prove native-refresh behavior on other macOS versions or in other products. Upovi keeps independent public catalog checks, shows the rejection, and provides Open App Store Updates. Native-only/build-only offers without an exact compatible target remain manual.

No Apple process identity was impersonated, private entitlement added or security setting changed. A fresh successful native-offer response on an allowed system still needs real-device acceptance. See [local evidence](evidence/automatic-updates-202611040006.json) for the signed rejection, isolated upgrade/restore tests and production-app boundaries.
