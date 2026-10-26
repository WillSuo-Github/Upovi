# Resumable downloads and administrator backup cleanup, 0.4.4

## Download recovery

ZIP, DMG and PKG preparation share a private artifact cache at `~/Library/Caches/Upovi/Downloads`. Cancellation, network failure and application restart retain partial bytes. Retrying the same source URL and integrity proof sends `Range` and `If-Range` only when a bounded total length and strong ETag were saved. HTTPS redirects retain those headers. An accepted 206 must match the offset, ETag, total length and response length. An ignored range (200) starts from zero; a rejected or invalid range gets one full-download fallback. Weak/missing validators start from zero. Encoded representations are refused to prevent byte-offset confusion.

Every completed or reused artifact must pass the selected SHA-256 or installed Sparkle Ed25519 proof before being copied to an installation workspace. Application signature, identity, version, executable compatibility and Gatekeeper checks still run. Corrupt cached artifacts are discarded. Cache files are private, bounded to 2 GB per download, and protected against links and concurrent process writes. Inactive entries older than seven days or beyond a soft 4 GB cache budget are pruned; active transfers are protected. Stable zero-byte lock files remain. Upovi self-updates use Sparkle's separate download path.

The HTTP validator rules follow [RFC 9110 If-Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5) and [Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-14.2). The final integrity proof remains mandatory even when a server accepts a range.

## Administrator cleanup

Settings → History and recovery shows protected transaction status and cached retained-data usage. **Inspect administrator record** requests system authorization to reconcile the authoritative root receipt. **Clean administrator backup** presents a permanent-deletion confirmation and requests authorization. Cleanup preserves the current application, receipt and installer log. It removes only the transaction's known retained app copies, package and expanded payload; it does not use Trash or run automatically.

The helper binds the request UUID, original application identity and selected version/build to the protected receipt. Only completed installs/restores whose current signed application still matches may begin cleanup. Older receipts without enough identity information are refused. Failed/interrupted installations keep recovery material. Before deleting any retained data, the helper durably revokes restoration in the receipt. Partial deletion remains visible and retryable; cancellation or an uncertain response requires an authoritative inspection. A completed cleanup cannot restore through this transaction.

Deletion stays inside the canonical transaction directory, rejects mounted external storage, does not traverse retained symlinks, and preserves unrecognized files. Reported usage is a bounded estimate, marked as a lower bound if its scan limit is reached. PKG script side effects are not undone by backup cleanup or application restoration.

## Verification

127 local tests passed (117 core, 10 store), including cold-cache resume, invalid/ignored ranges, weak validators, integrity failures, locking, retention and symlinks; cleanup coverage includes failed revocation writes, partial deletion/retry, identity mismatch and request binding.

`script/acceptance/download_resume.swift` canceled an actual official Rectangle 2.0.4 HTTPS ZIP after 16,375 bytes, recreated the cache actor, observed a validated 206 from offset 16,375, and verified SHA-256 `0b9b8b11edeb3237e3224c619a6f6bfb5e5996a477048be6ff4b98b0346aedc9`. This is a real public-network transfer with a new downloader instance, not an application-crash simulation.

`script/acceptance/build_bulk_fixture.py --mode admin-cleanup` creates an explicitly isolated signed fixture with the production helper. The native acceptance uses only `/Applications/Upovi Download Cleanup Acceptance.app`, with user-completed macOS authorization. Native installation 2.0.3 → 2.0.4, cleanup cancellation, authorized cleanup, authoritative zero-byte inspection, rejected post-cleanup restore, and cleaned history after cold restart passed. The exact final signed helper also passed receipt synchronization during inspection. The isolated target was then moved out of /Applications. Its result is recorded in [version-specific evidence](evidence/0.4.4-resume-cleanup.json). Raw snapshots and local receipts stay private. No normal installed application is replaced.

Real PKG script execution, administrator interruption/reboot recovery, newer-version long observation, self-update publication and notarization remain separate work. The existing 0.4.2 observer is unchanged; its elapsed time does not validate 0.4.4.
