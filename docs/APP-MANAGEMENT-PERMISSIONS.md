# App Management permission guidance

Upovi shows a skippable permission guide on the first launch that has not acknowledged this guide. Existing installations also see it once when upgrading from a build without the guide. Skipping does not disable scanning or update checks, and visiting System Settings never records consent as granted.

The guide opens System Settings → Privacy & Security → App Management. It identifies the App Store installer as **Upovi Installer**, also shown by some systems as **UpoviStoreInstaller**, and explains that macOS may separately request access for Upovi. If the installer is missing from the permission list, **Show Installer in Finder** selects the embedded installer application so the user can add it with the system's “+” button. The installer is only revealed, never executed by the guide. Permission changes remain the user's action in System Settings.

Settings → Scanning & Installation retains an entry to reopen the guide. The main app and the bundled Store installer include Apple's [NSAppBundlesUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappbundlesusagedescription) purpose text.

## Permission failures and recovery

Typed Store permission failures are retained as blocked application references in private preferences and classified as `permissionDenied` in diagnostic snapshots. Non-permission Store errors, including a full disk, keep their original handling. A failed batch presents one aggregated guide after the remaining jobs finish; it does not interrupt each job with a modal. Unrelated later batches do not repeat a previously dismissed permission guide. A reminder on the Updates page remains available after dismissal and restart.

**Recheck Blocked Apps** selects the latest failed Store entry for each blocked application, refreshes the inventory and sources, and opens the existing update confirmation. Completed apps, tools and unrelated failures are excluded. Returning from Settings, dismissing the guide or reopening Upovi never retries installation. Only an explicit update confirmation can start a new attempt. Blocked task references clear after an observed successful/current installation outcome; a source check alone does not clear them.

The app does not read or modify the TCC database and does not infer permission state from an opened Settings page. A settings-launch failure or missing helper is explained inline. System settings links can vary by macOS version, so the manual navigation path remains visible. Native settings navigation was verified on macOS 27.2.1; the permission toggle itself was not changed.

## Local validation

Build `202611140002` retains marketing version `0.4.10`. Validation includes 323 core tests, 63 application workflow tests and 41 Python tests, followed by focused permission/diagnostic/log checks after the final batch-presentation refinement. A Release build and strict nested signature verification passed.

Isolated native views exercised first-launch skipping, grouped synthetic Store denials, persistent reminders, Settings and Finder navigation, reopening the guide from Settings, and explicit recheck returning to update confirmation. The final installer-name wording was visually checked. Production diagnostic export preserved both permission-denial codes and matching application references while removing sentinel secrets and raw paths. No real applications were updated, no permission switches were changed, and temporary native test applications were stopped and removed. This is a local implementation, not an installed or published update. See [validation evidence](evidence/app-management-202611140002.json).
