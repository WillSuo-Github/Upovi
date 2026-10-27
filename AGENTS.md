# Upovi versioning

- Keep `MARKETING_VERSION` / `CFBundleShortVersionString` unchanged for routine updates. Change the marketing version only when the user explicitly asks to prepare a new formal version.
- Allocate one new build for each update with `python3 script/release_metadata.py bump-build`. This synchronizes `Resources/Release.json` and `Config/Release.xcconfig` without changing the marketing version.
- Build numbers use `YYYYMMDDNNNN` in `Asia/Shanghai`, starting at `0001` each day. Never reset, reuse or decrease a build number. Ordinary rebuilds and retries use the already allocated number.
- Read archive names, GitHub build tags and download URLs from `script/release_metadata.py show`. Routine build tags are `build-<build>`; archive names include both marketing version and build number. Sparkle compares the build number.
- Preparing a build or changing numbering does not itself authorize publishing a new download. Follow the user's requested distribution scope and validate signatures, notarization and the final signed feed before any authorized publication.
