# Global tool updates

Settings → Tools contains independent, persistent opt-in switches. All are off by default. Enabling a source checks its inventory; installation starts after confirming Update All. The toolbar Refresh and Check action checks applications and enabled global tools together. Each outdated package is a separate row alongside desktop applications, sorted by name, with installed/target versions and a source label. Each row supports a targeted update; Update All includes all pending packages. Successful packages leave the list and retain individual records in History & Recovery. Source-check failures appear as compact diagnostics rather than aggregate package rows. Missing managers are shown as unavailable and are never installed automatically.

| Source | Update scope |
| --- | --- |
| Homebrew | `brew upgrade --formula -- <name>` for each reviewed outdated formula; respects pinned formulae. Casks remain in the existing desktop-app update flow. |
| npm | Outdated top-level global packages in the current prefix, installed at the checked registry version. Homebrew/Volta-owned npm and Corepack stay with their runtime. |
| pnpm | Outdated top-level global packages in the current global root. |
| uv tools | Standalone `uv tool` installations without explicit version requirements. Explicit constraints are held. |
| pipx | Unpinned main packages in existing pipx environments. Requires `--skip-maintenance` support so inventory checks do not silently update shared libraries. |
| Cargo | Existing `cargo-update` inventory and targeted upgrades; requires both Cargo and cargo-install-update. |
| Rust toolchains | Existing stable, beta and nightly channels via rustup, with `--no-self-update`. Fixed toolchain versions remain untouched. |

Only global tools are managed. Upovi does not edit project dependencies, manifests or lock files, update system-provided Python/Ruby, discover arbitrary binaries, or install missing managers/plugins. It uses one discovered executable/environment per source, not every Node/Python environment on the machine. Discovery checks the launch PATH and common user/package-manager locations; agent-private runtime paths are excluded.

## Execution and results

App updates run first, followed by individual reviewed tool packages sequentially. Every package is one task with independent progress, success/failure, retry and history. Enabled sources without outdated packages create no update tasks. A single-package action cannot request a source-wide upgrade; the native manager may still update dependencies required by that package. Checks can access configured registries and update manager caches; they do not run package upgrade commands.

Commands use argument arrays and a private neutral working directory. They do not use a shell or sudo. Existing managers retain ownership of registries, credentials, constraints and installation scripts. Source and target names are validated; npm/pnpm global scope is checked again before and after a write. A native installation can run package scripts and is not an Upovi desktop-app backup transaction.

Before writing, Upovi rechecks the selected package, source context and version constraints. A changed target requires a fresh review. After each package finishes, Upovi checks the inventory again. Exit status zero alone does not mean success: the selected package must reach its reviewed target (or a newer installed version). Already-current targets finish successfully without another install, and other outdated packages do not make this package fail. Failures retain a bounded, sanitized diagnostic. Raw pipx metadata and command credentials are not stored in tool history or shared over P2P.

Stop finishes the current package and skips remaining packages. An interrupted application session is recorded as interrupted on the next launch and never automatically resumes an installation. History & Recovery → Global Tools shows package results (legacy source records remain readable); package-manager changes do not offer Upovi application rollback.

Finished runs show a completed-task count and any unfinished count, rather than labeling every handled task as successfully updated. A partial result retains the failed rows and one retry action; a successful run links to its saved history. Refresh clears the old result summary while checking both application and tool sources again. Manual-channel applications remain separate from automatic task totals, including in batch history.

Administrator installation uses the existing conservative protected-backup/expansion space policy before package downloads and before authorization. The root helper rechecks the same policy before copying the backup. Insufficient-space messages report required and available bytes and ask the user to free space before retrying; this does not lower the space reserve or delete retained backups.

## Local validation

The current UI was also checked with a mixed offline app/tool list: individual updates, one-package failure, sibling success, targeted retry and per-package history. A real private-prefix npm run upgraded mkdirp 2.1.6 → 3.0.1 while semver stayed 7.6.3, then Update All upgraded only the remaining semver to 7.8.5. No user global prefix was changed.

The Swift suite covers native output parsing, manager discovery, pins/constraints, command arguments and accepted read statuses, scope changes, post-install verification, opt-in persistence, package-only batches, same-source partial failures and targeted retries, stop boundaries and interrupted histories. Native npm acceptance uses a private explicit prefix with semver 7.6.3 and verifies the installed upgrade to 7.8.5 without changing the user's global prefix. The startup acceptance fixture supports `--tools-preview` for this isolated native UI flow; Update All and the completed version transition in Global Tools history were verified through the native interface. The signed 0.4.10 (202610310001) local app was installed and its settings, detection, mixed confirmation and default-off restoration were checked. This is local validation, not a published or notarized release.

## Completion when another updater finishes first

A downloaded-app task can finish as `current` when the selected release or a newer release is already installed. Upovi verifies the real installation path, exact bundle identity, developer Team ID, Apple Developer ID signature and comparable version/build before skipping replacement. It checks before preparation and again before committing; batch failure handling also rechecks for an external completion. A current result creates no installation receipt or backup and does not count as a failed task. Original-path transaction guards still reject unrelated, unsigned, linked or uncomparable replacements.

For Homebrew casks that publish `short,full` and installed apps that use the full version in both bundle version keys, the declared full version is the exact download target. This handles Toolbox-style metadata without accepting arbitrary version-prefix matches or weakening signature/checksum validation.

pnpm inventory uses its documented `outdated --global --format json` option, rather than the npm-specific `--json` switch. Empty array/object inventories are accepted.

Command references: [pnpm outdated](https://github.com/pnpm/pnpm.io/blob/main/docs/cli/outdated.md), [Homebrew](https://docs.brew.sh/Manpage), [npm outdated](https://docs.npmjs.com/cli/v11/commands/npm-outdated/), [uv tools](https://docs.astral.sh/uv/concepts/tools/), [pipx](https://pipx.pypa.io/stable/reference/cli/), [cargo-update](https://github.com/nabijaczleweli/cargo-update), [rustup](https://rust-lang.github.io/rustup/basics.html).
