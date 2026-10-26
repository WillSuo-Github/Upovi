# Diagnostic export and source coverage, 0.4.5

## Local diagnostic reports

Settings → General → Diagnostics and feedback opens a frozen report preview. Saving uses the native macOS export panel. Canceling saves nothing and does not show a success message. The optional application-identifiers switch starts off for every new preview; it is never persisted. Saved bytes come from the same frozen snapshot and selected disclosure mode shown in the preview.

The default JSON contains product/OS version and architecture, network availability, whether an operation is active, per-application temporary references, source-check outcomes and classified failures, plus bounded transaction states and recent operation issues. It excludes application names, bundle IDs, installed versions/builds, paths, Team IDs, source/download URLs, query parameters, raw errors/logs, release notes, device names, IP addresses and peer identities. Opting in adds only validated bundle IDs and installed versions/builds; it does not enable raw-message or URL export. Temporary references are local to each snapshot, not stable identity hashes. No report is uploaded automatically.

Reports use a typed allowlist projection rather than attempting to scrub arbitrary log text. Source failures record their adapter, outcome, fixed issue category, numeric URL error code or HTTP status. HTTP response failures now preserve the status (including 403/404/429) without capturing the requested URL. Operation failures record preparation, installation, recovery, inspection or cleanup; they do not claim to distinguish individual verification substeps. Up to 50 recent operation issues survive relaunch in the existing private settings file. Current source results are a memory snapshot and appear as `notChecked` after a relaunch until checked again.

Each export includes at most 1,000 applications, eight source details per application, 50 recent issues and 200 transaction summaries, with an explicit truncation flag and a 2 MB final encoding limit. Missing or removed applications receive no exported internal path. `verifiableDownloadCount` means the candidate carries an integrity proof; it does not claim that the archive has been downloaded or verified.

## Source coverage

- LiveHub's exact `com.willsuo.livehub` identity now checks [its official repository](https://github.com/WillSuo-Github/livehub-desktop/releases). The installed bundle and repository build configuration establish the mapping. Similar application names do not match.
- PlayCover's exact `io.playcover.PlayCover` identity adds [official GitHub releases](https://github.com/PlayCover/PlayCover/releases) alongside its existing appcast. The identifier is declared in the [upstream project](https://github.com/PlayCover/PlayCover/blob/develop/PlayCover.xcodeproj/project.pbxproj). A failed appcast remains a visible partial check even when GitHub succeeds.
- Stable VSCodium's exact `com.vscodium` identity maps to the [official cask](https://formulae.brew.sh/api/cask/vscodium.json). Its identity is declared in the [upstream build script](https://github.com/VSCodium/vscodium/blob/master/prepare_vscode.sh). The Insiders identifier is not routed to the stable cask.
- Homebrew app artifacts now preserve explicit renamed `.app` targets in heterogeneous arrays and top-level target metadata. Unsafe/non-application target paths are ignored. The selected platform's artifact declarations determine whether a DMG/ZIP contains a directly replaceable app; a package-only platform variation is not offered as an app replacement.

The same-machine source check retained 71 applications. Unsupported entries fell from six to five after LiveHub adaptation; one remaining unsupported entry is synthetic. Source requests also experienced different transient TLS behavior between runs, so the reduction in failed/partial counts is not attributed entirely to code. Raw inventories and notes remain in the private `.local/diagnostics-sources` directory. These counts do not measure installation success or universal application coverage.

## Verification and boundaries

141 local tests passed: 128 core and 13 actual-store tests. New tests cover poisoned raw messages/URLs/paths and error userInfo, default and optional identity disclosure, bounded exports and frozen snapshots, persisted single-install failures, exact source identities, HTTP rate limits, partial fallback failures, heterogeneous artifacts and platform-specific packaging. Synthetic native acceptance exercises the real Settings/report/export views while scanning, networking, notifications and administrator operations are disabled. Its fixture contains conspicuous raw secrets to verify that exports exclude them.

Native export acceptance passed default redaction, explicit identifier inclusion, cancel-without-success, reset on reopening and byte-identical preview/export. A stale accessibility preview value discovered during acceptance was repaired and retested in both toggle directions. The signed universal package and source revision 9e2529c also passed signature/feed/archive verification and all three macOS CI jobs.

See [version-specific evidence](evidence/0.4.5-diagnostics-sources.json) for actual native export, signed artifact and CI results. No application is installed by the source/diagnostic acceptance. Actual PKG execution, privileged interruption/reboot, newer-version long observation, self-update publication and notarization remain separate work. The existing 0.4.2 observer retains its own version and scope.
