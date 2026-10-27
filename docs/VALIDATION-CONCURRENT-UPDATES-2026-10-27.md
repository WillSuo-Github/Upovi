# Concurrent batch updates and row progress — 2026-10-27

Batch updates now run up to `bulkConcurrency` applications at once (default 5, Settings range 1–8). Each application row on the Updates page shows its own animated progress bar; the Updates hero becomes an overall progress card for the batch, and the sidebar footer shows a compact overall bar. The floating bottom pill no longer appears for downloads.

Administrator-authorized and App Store installations pass through a FIFO `SerialGate`, so at most one system authorization prompt is shown at a time. Direct user-writable replacements run concurrently. `UpdateInstaller` locks per application path and can hold several prepared updates; restore and backup cleanup remain exclusive.

## Automated

All 200 local Xcode tests passed (176 core, 24 app), including:

- concurrency limit reached exactly and outcome order preserved;
- stop lets running items finish and cancels queued items;
- `SerialGate` never overlaps;
- three concurrent requests for one artifact make a single network transfer;
- a cancelled queued artifact request returns without waiting for the active transfer.

## Isolated real-application acceptance

`script/acceptance/build_bulk_fixture.py --mode bulk` with three isolated copies of the official signed Rectangle 2.0.3 (A, B, C) and the official Rectangle 2.0.4 ZIP. B uses the fixture's intentionally wrong SHA-256 until "Repair fixture source".

First run found a regression: A and C download the same artifact concurrently, and `ArtifactDownloadCache` rejected the second with "This artifact is already being downloaded". The cache now queues same-instance callers for one key and serves them from the verified entry; separate instances and processes stay excluded by the file lock.

After the fix, on a fresh fixture:

- all three rows downloaded concurrently ("3 个下载中");
- A and C installed 2.0.4 (111); B failed with "Downloaded archive checksum mismatch";
- after repairing the source, "重试未完成项" installed B; the hero turned green;
- all copies are 2.0.4 (111), pass `codesign --verify --deep --strict` with Team ID `XSYZ3E4B7D`, keep `.upovi-backup-*` copies, and have three `installed` journal receipts.

The synthetic design preview (`--present bulk-demo`) was also reviewed for running, completed and failed states.

Not covered: concurrent administrator/App Store installations with real prompts, light appearance, Reduce Motion, and batches of more than three real applications. The normal installed applications were not touched; fixture processes were stopped and fixture directories moved to Trash.
