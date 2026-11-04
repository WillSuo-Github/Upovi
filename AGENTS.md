# Upovi versioning

## User-initiated installation only

- Every update installation must follow an explicit user action, such as Update or Update All. Never add unattended, startup-triggered, scheduled, or notification-triggered installation, including per-app opt-ins.
- Automatic checks may discover updates and notify the user, but must not download or install them. Upovi's Sparkle self-updater must also disable automatic downloading and installation, regardless of saved preferences.

## Build identities

- Keep `MARKETING_VERSION` / `CFBundleShortVersionString` unchanged for routine updates. Change the marketing version only when the user explicitly asks to prepare a new formal version.
- Allocate one new build for each update with `python3 script/release_metadata.py bump-build`. This synchronizes `Resources/Release.json` and `Config/Release.xcconfig` without changing the marketing version.
- Build numbers use `YYYYMMDDNNNN` in `Asia/Shanghai`, starting at `0001` each day. Never reset, reuse or decrease a build number. Ordinary rebuilds and retries use the already allocated number.
- Read archive names, GitHub build tags and download URLs from `script/release_metadata.py show`. Routine build tags are `build-<build>`; archive names include both marketing version and build number. Sparkle compares the build number.
- Preparing a build or changing numbering does not itself authorize publishing a new download. Follow the user's requested distribution scope and validate signatures, notarization and the final signed feed before any authorized publication.

# Runtime diagnostics

- New or changed check/download/authorization/install/recovery paths must keep useful runtime diagnostics at `info` or above in ordinary builds. Record operation boundaries, important state transitions and terminal errors/cancellation using `UpoviLog`, `UpoviLogOperation` and the shared correlation context.
- Preserve the user-exported diagnostic ZIP and `snapshot.json` ↔ `runtime.log` application references. See `docs/DIAGNOSTICS.md` for retention, privacy and coverage requirements.
- Never log credentials, raw commands/arguments, environment values, response bodies or complete app/configuration objects. Use pseudonymous references and fixed helper error projections. Keep logging bounded and asynchronous; do not add per-chunk or per-tick logs.
- When changing diagnostics, verify production-path events, failure/cancellation, redaction, retention and export rather than only checking that the project compiles.
