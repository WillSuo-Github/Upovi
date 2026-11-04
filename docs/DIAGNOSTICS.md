# User-exported diagnostics and runtime logs

The file logger is adapted from Vunio's `Support/Logging` subsystem: the same asynchronous serial writer, bounded admission, session IDs, UTC records, daily/size rotation, retention and export-time redaction. Upovi adds operation parents, update-specific categories, pseudonymous app references and a ZIP combining the timeline with its existing structured snapshot.

## User flow

Open **Settings → About → Diagnostics → Preview and Export Diagnostic Report…**, or the same action in **Help**. The sheet shows the check summary and can preview the latest 128 KiB of retained runtime logs. Keep **Include recent runtime logs** enabled for troubleshooting, optionally include application identifiers/versions in the snapshot, then choose **Export Diagnostic Bundle…** and a save location. Files are never uploaded automatically. The developer receives only what the user chooses to share.

The ZIP contains:

- `manifest.json`: export time, app version/build/source revision, current session, OS/architecture, uptime, time zone/locale and retention limits.
- `snapshot.json`: schema 2 check statuses, source failures, HTTP/retry classifications and recent transactions. `logReference` maps each temporary application reference to `app=` in the timeline. Raw application paths remain excluded; bundle identifiers and snapshot versions require the per-export opt-in.
- `runtime.log`: retained sessions in chronological file order, including bounded error descriptions, underlying domain/code chains, versions, operation/request/parent IDs, timings and state changes.
- `README.txt`: interpretation, retention, collection boundaries and information to include with feedback.

The snapshot is frozen when the sheet opens so the user can review what will be shared; runtime logs are captured when preparing the export. Their independent timestamps identify that boundary. Logs may reveal software context through version/error details even without the identifier opt-in. Review the preview and exported files before sharing. Excluding runtime logs still allows a summary-only ZIP if log storage is unreadable.

## Storage, performance and failure reporting

- Production path: `~/Library/Application Support/Upovi/Logs`.
- Logs are enabled in ordinary builds. Release retains `info` and above; debug retains additional `debug` records.
- Per file: 5 MiB. Total: 40 MiB, at most 200 retained files, at most 14 days; oldest is removed first. Files also rotate at a new UTC day/session. Size/count limits can shorten the retained history.
- Per record: 16 KiB on a valid UTF-8 boundary. Pending writer work: at most 1 MiB, with part reserved for warnings/errors. An overloaded writer counts dropped records in the export header.
- A utility queue owns handles, timestamps, rotation, pruning and snapshots. Log files have mode `0600`; the directory has mode `0700` and is excluded from backup. New files use exclusive creation without following symlinks. Only matching regular files owned by the current user are read; retained reads and export sizes are bounded.
- Error/fault entries synchronize after writing; ordinary app termination flushes the queue. A force kill, power loss or crash can still lose pending entries. No unsafe signal handler is installed and no promise of complete crash capture is made.
- Export runs off the UI actor and serializes with writes/rotation. An unreadable/corrupt retained log fails export visibly instead of silently returning a complete-looking timeline. The last writer IO failure and dropped count appear in a successful snapshot header. The final archive is capped at 50 MiB and temporary staging files are removed on completion/failure/cancellation.

## Coverage

| Area | Recorded evidence |
| --- | --- |
| Lifecycle/storage | Launch/version/source revision, termination, preferences/history persistence failures, manual refresh/cancellation, inventory counts, P2P sync boundaries, self-update request and postponed relaunch |
| Source checks | App reference, installed/target/client versions, channel/override presence, every source outcome, retained/expired/identity-changed evidence, Steam local-evidence rejection and official build comparison, GitHub fallback confirmation/rejection |
| HTTP metadata/artifacts | Origin family and sanitized-location hash, parent/request ID, limit, cache/conditional result, attempt/retry, explicit cooldown/reset, response status/size/MIME, redirect decision, completion/error and elapsed time |
| Downloads | Download UUID, app reference, queue/state transitions, retries, pause/network wait/resume, resumed bytes, verification and coarse 25% progress milestones |
| Preparation/install/recovery | Requested target, archive proof/format, verification/preparation IDs, application quit, batch ID/concurrency/phase, administrator transaction/receipt state, installed version, finalization domain/code, restore/cleanup requests and persisted outcomes |
| Authorization | Prompt versus shared-session route, upfront session readiness, each submitted item/index/result, stop/finish, cancellation and duration; raw scripts/arguments/results are excluded |
| Helpers/tools | Subprocess basename, argument count, timeout, exit status/reason/output byte count without body; tool source and pseudonymous package identity; Store receipt/failure stage/domain/code and app-management classification |

Privileged helpers never write user-controlled log files as root. Their JSON protocols are unchanged. On helper failure, a fixed `UPOVI_INSTALLER_DIAGNOSTIC` marker conveys only the stage and allowlisted error domain/numeric code through the already-existing error stream. The host projects those fields into its timeline; it does not collect the raw authorization/system/installer log. Successful or pending-finalization typed receipts are recorded by the host. This is not unrestricted access to macOS TCC/system logs or a replacement for vendor diagnostics.

## Privacy and future instrumentation

Use `UpoviLog.<category>.<level>` for state transitions and `UpoviLogOperation` for paired asynchronous work. `UpoviDiagnosticContext.operationID` links child work; detached installer verification uses the context-preserving helper. Correlate `request`/`parent`, batch/download/transaction IDs and `app=` rather than dumping objects. Source identities exclude URL credentials/query/fragment before hashing, and origin families avoid exporting private server hosts or repository paths.

Never log passwords, tokens, command arguments/scripts, environment values, request/response bodies, complete application/configuration objects or arbitrary user content. Sink-level redaction filters recognizable credentials, authorization/cookie fields, URLs and common absolute paths, escapes newlines to prevent forged records, and repeats redaction on old retained files. This is pattern filtering, not a guarantee that arbitrary text cannot contain secrets. Bounded error descriptions retain static permission/validation reasons; raw helper/Store outputs are replaced with structured classifications.

New source/install/download paths must record significant transitions and terminal failure/cancellation at shipping levels. Do not log each byte chunk or scheduler tick. Test correlation and cancellation, bounded storage/export, redaction, file IO failure and preservation of transport/installation behavior. `UpoviLogTests`, existing source/download/installation tests and an isolated native export cover these contracts. Developer/test builds may redirect the sink using `UPOVI_LOG_DIRECTORY`; Release ignores this environment override, and root helpers always disable file writes.

## Implementation validation (build 202611040014)

The local working tree passed 294 core tests, 59 application workflow tests and eight release-metadata tests. An isolated native app previewed the sanitized runtime timeline and successfully saved a ZIP through the real save panel. The exported payload preserved matching application references, an NSCocoa 513 → POSIX 1 permission chain, operation IDs and duration, without sentinel credentials or paths; the saved file had mode `0600`. Native testing found and corrected an Objective-C exception caused by setting attributes on the FileDocument wrapper; file permissions are now tightened after the save completes.

The final archive writer additionally removes Apple filesystem metadata, verified by an independent unzip listing regression, and expected current/cancelled operations are retained at info level. A universal Xcode Release build passed resource/signature checks, and the final helper emitted the fixed safe denial marker when invoked without privilege. This is a local ad hoc verification build, not a notarized/public release or an installed-app acceptance. No real app update or privileged transaction was performed. All temporary native/verification app copies were stopped and removed. See [validation evidence](evidence/logging-202611040014.json).
