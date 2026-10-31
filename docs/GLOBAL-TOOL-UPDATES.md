# Global tool updates

Settings → Tools contains independent, persistent opt-in switches. All are off by default. Enabling a source checks its inventory; installation starts only after confirming Update All or Update This Source. Missing managers are shown as unavailable and are never installed automatically.

| Source | Update scope |
| --- | --- |
| Homebrew | `brew update`, then `brew upgrade --formula`; refreshes Homebrew and its indexes, respects pinned formulae. Casks remain in the existing desktop-app update flow. |
| npm | Outdated top-level global packages in the current prefix, installed at the checked registry version. Homebrew/Volta-owned npm and Corepack stay with their runtime. |
| pnpm | Outdated top-level global packages in the current global root. |
| uv tools | Standalone `uv tool` installations without explicit version requirements. Explicit constraints are held. |
| pipx | Unpinned main packages in existing pipx environments. Requires `--skip-maintenance` support so inventory checks do not silently update shared libraries. |
| Cargo | Existing `cargo-update` inventory and targeted upgrades; requires both Cargo and cargo-install-update. |
| Rust toolchains | Existing stable, beta and nightly channels via rustup, with `--no-self-update`. Fixed toolchain versions remain untouched. |

Only global tools are managed. Upovi does not edit project dependencies, manifests or lock files, update system-provided Python/Ruby, discover arbitrary binaries, or install missing managers/plugins. It uses one discovered executable/environment per source, not every Node/Python environment on the machine. Discovery checks the launch PATH and common user/package-manager locations; agent-private runtime paths are excluded.

## Execution and results

App updates run first, followed by enabled tool sources sequentially. A source is one task and can cover multiple packages. Enabled sources still participate when no package is currently outdated, allowing Homebrew itself and its index to refresh. Checks can access configured registries and update manager caches; they do not run package upgrade commands.

Commands use argument arrays and a private neutral working directory. They do not use a shell or sudo. Existing managers retain ownership of registries, credentials, constraints and installation scripts. Source and target names are validated; npm/pnpm global scope is checked again before and after a write. A native installation can run package scripts and is not an Upovi desktop-app backup transaction.

After each source finishes, Upovi checks the inventory again. Exit status zero alone does not mean success: selected package versions must change and no eligible updates may remain. Failures retain a bounded, sanitized diagnostic. Raw pipx metadata and command credentials are not stored in tool history or shared over P2P.

Stop finishes the current source and skips the remaining sources. An interrupted application session is recorded as interrupted on the next launch and never automatically resumes an installation. History & Recovery → Global Tools shows source results; package-manager changes do not offer Upovi application rollback.

## Local validation

The Swift suite covers native output parsing, manager discovery, pins/constraints, command arguments and accepted read statuses, scope changes, post-install verification, opt-in persistence, source-only batches, stop boundaries and interrupted histories. Native npm acceptance uses a private explicit prefix with semver 7.6.3 and verifies the installed upgrade to 7.8.5 without changing the user's global prefix. The startup acceptance fixture supports `--tools-preview` for this isolated native UI flow; Update All and the completed version transition in Global Tools history were verified through the native interface. The signed 0.4.10 (202610310001) local app was installed and its settings, detection, mixed confirmation and default-off restoration were checked. This is local validation, not a published or notarized release.

## Completion when another updater finishes first

A downloaded-app task can finish as `current` when the selected release or a newer release is already installed. Upovi verifies the real installation path, exact bundle identity, developer Team ID, Apple Developer ID signature and comparable version/build before skipping replacement. It checks before preparation and again before committing; batch failure handling also rechecks for an external completion. A current result creates no installation receipt or backup and does not count as a failed task. Original-path transaction guards still reject unrelated, unsigned, linked or uncomparable replacements.

For Homebrew casks that publish `short,full` and installed apps that use the full version in both bundle version keys, the declared full version is the exact download target. This handles Toolbox-style metadata without accepting arbitrary version-prefix matches or weakening signature/checksum validation.

Command references: [Homebrew](https://docs.brew.sh/Manpage), [npm outdated](https://docs.npmjs.com/cli/v11/commands/npm-outdated/), [uv tools](https://docs.astral.sh/uv/concepts/tools/), [pipx](https://pipx.pypa.io/stable/reference/cli/), [cargo-update](https://github.com/nabijaczleweli/cargo-update), [rustup](https://rust-lang.github.io/rustup/basics.html).
