# Administrator installation design

The user selected an Upovi-managed installer on 2026-10-25. P2P does not participate in authorization, source selection or installation.

## Authorization and execution

- Request macOS administrator authorization for each installation or recovery; macOS controls credential presentation and any authorization reuse. Never save or collect passwords, install a persistent daemon, or invoke a vendor installer without the user's installation confirmation.
- Embed a dedicated universal `UpoviInstaller` executable. The authorization bootstrap first copies it into a root-owned temporary directory, verifies its Developer ID requirement against the running Upovi team, and only then executes the protected copy. The root process accepts a bounded JSON plan, validates application identity and restricts destinations to immediate `.app` children of `/Applications` with no symlink ancestors.
- The root process copies artifacts into a private root-owned transaction directory before verification/use. ZIP/DMG replacements reuse the existing prepared-app identity, complete code-signature, compatibility and Gatekeeper checks. A signed app bundle moves atomically only when the transaction and destination are on the same volume.
- Direct PKGs require archive integrity and a Developer ID Installer signature from the installed application's team. Expand the package without executing scripts, bound expansion time/size, and require a payload containing exactly one matching signed app/version before allowing `/usr/sbin/installer`. Packages that only fetch their payload in scripts, cannot be inspected, or require an unsupported destination remain manual workflows.

## Journaling and recovery

Before running any package scripts or replacing an application, retain a verified copy of the original app and a journal under `/Library/Application Support/Upovi/PrivilegedInstallations/<UUID>`. The directory is root-owned and private; recovery reads the authoritative root journal, never trusts a supplied backup path, verifies the retained signature, and refuses to overwrite an unrelated or externally updated app. The normal app retains a private attempt record so interruption remains visible after relaunch. Recovery requires a new authorization prompt.

PKG scripts may modify receipts, launch services, drivers, files and data outside the application bundle. Restoring the retained app is **application recovery only**, not a complete rollback of package side effects. UI confirmation and history must disclose this boundary. Failed/interrupted transactions keep their recovery material; no automatic pruning runs.

## Acceptance

Unit tests must cover plan bounds and destinations, quoted authorization arguments, wrong signer/team, package payload identity/version, stale restoration, interrupted journals and retained backups. Packaging must sign and verify the helper on both architectures. Native UI acceptance can inspect consent and cancellation; a real privileged install, rejection/cancellation, and reboot/interruption behavior need separate recorded acceptance. Passing compilation or unprivileged tests does not establish privileged execution success.

## Protected backup cleanup (0.4.4)

Completed installs/restores offer authorized inspection and permanent cleanup in History and recovery. The helper validates the authoritative transaction and matching current signed app, revokes restoration durably, then deletes only known retained data. Incomplete deletion can be retried; failed/interrupted installs cannot begin cleanup. Receipts and installer logs stay protected. See [download and cleanup details](DOWNLOAD-RESUME-AND-CLEANUP.md).
