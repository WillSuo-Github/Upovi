# App Management access help

Upovi does not require a separate permission setup or Verify Access action. Startup and update checks never present a permission sheet, request administrator authorization or test writes. An empty cache, old probe denial, app upgrade or absence of prior write results is not treated as missing permission.

The user reviews and confirms Update or Update All, then the normal signed installer performs its work. Store updates keep their existing pre-download write check inside that same confirmed operation. If the system needs consent, it may present its own prompt. If the operation is refused, Upovi preserves the failed item and its diagnostic information. It does not turn a failed write into a claim that the App Management switch is off, or automatically present a setup modal.

The Updates reminder appears only for actual failed updates retained in batch history. It says that earlier updates await retry; it is not a live permission warning. **Recheck Blocked Apps** refreshes those targets and returns to the update confirmation page. Rechecking, returning from System Settings and reopening Upovi never start installation. A successful retry clears the corresponding failed-access reminder.

**Access Help** is optional and user-initiated, available beside failed updates and in Settings. It offers the matching System Settings and installer Finder locations, without a Not Verified status, Verify Access button or extra administrator prompt. Component availability reflects only whether the bundled installer exists. **Open Settings** goes directly to System Settings → Privacy & Security → App Management. The embedded helper may appear as **Upovi Installer** or **UpoviStoreInstaller**. If its switch is already on, the user should leave it enabled; further failures require diagnostics rather than repeated switch changes.

macOS does not expose a general public TCC status API. A file write may be denied by App Management, ordinary file permissions, security software or another protection mechanism. The app must not infer the exact switch state from an NSCocoa 513 or POSIX EPERM/EACCES error. Apple's [On File System Permissions](https://developer.apple.com/forums/thread/678819) explains these error sources, responsible code and the lack of a TCC API surface. Upovi uses neither private TCC APIs nor database reads/modifications to invent a permission status. It also does not request Full Disk Access to inspect the permission database.

Historical successful writes are retained as internal diagnostic evidence, not displayed as current permission approval. Opening System Settings does not erase real operation history or record consent. New write failures still invalidate outdated success evidence. The main application and Store installer retain Apple's [NSAppBundlesUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappbundlesusagedescription) purpose text.

The probe-only protocol remains available for internal isolated diagnostics and its safety tests. It is not reachable from the normal app UI. It accepts only typed write probes, cannot install or repair receipts, and is never launched automatically.

Earlier releases and acceptance records describe the previous setup/verification interface. They remain historical evidence, not the current user flow. See [build 202611160001 release evidence](evidence/0.4.10-build-202611160001.json) for that published artifact; this interface correction is a subsequent change.

## Publication

The [signed universal build 202611160002](https://github.com/WillSuo-Github/Upovi/releases/tag/build-202611160002) publishes this on-demand access-help flow as Latest. Marketing version 0.4.10 is unchanged. Notarization, Gatekeeper, signed feed/archive, component signatures and public downloaded bytes passed verification. See [release evidence](evidence/0.4.10-build-202611160002.json).
