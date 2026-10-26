# Native Xcode project

Open `Upovi.xcodeproj`, select the **Upovi** scheme and **My Mac**, then use Cmd-R to run, Cmd-U to test, or Product > Archive. The checked-in project is a native Xcode project and does not require XcodeGen to open or build. It supports Swift 6, Xcode 16 or newer, and macOS 14 or newer.

## Targets

| Target | Product | Purpose |
| --- | --- | --- |
| Upovi | macOS SwiftUI application | Main application, assets, Sparkle and embedded installer tools |
| UpoviCore | Static Swift library | Shared models, networking, source adapters and installation logic |
| ArchiveSupport | Static C library | Bounded ZIP extraction using the system libarchive |
| UpoviInstaller | Command-line tool | Per-operation administrator installation and recovery |
| UpoviStoreInstaller | Command-line tool | Protected App Store update operations |
| UpoviPeer | Command-line tool | Existing diagnostic and synthetic-network commands |
| UpoviCoreTests | XCTest bundle | Core, installation and recovery tests |
| UpoviTests | Hosted XCTest bundle | Application workflow tests |

The app uses the existing `@main UpoviApp` entrypoint and the original source files. Static core libraries keep the administrator helpers self-contained after they are copied into a protected temporary directory. The only remote package dependency of the native project is Sparkle, pinned to 2.10.0.

## Build settings and resources

- `Config/Release.xcconfig` supplies the version and build number to Xcode. Synchronize those values with `Resources/Release.json` when preparing a release. Xcode's version/build settings are passed to the metadata writer; the JSON file continues to own the feed URL and public signing key.
- The metadata build phase writes an intermediate Info.plist under DerivedSources. It retains the existing bundle ID, minimum system version, local-network usage description, Sparkle security settings and source revision.
- `Resources/Assets.xcassets/AppIcon.appiconset` contains the existing icon in Xcode's macOS asset-catalog format.
- Xcode embeds Sparkle and the two installer targets. The final resource phase embeds the existing checksum-pinned mas Store bridge, applies the explicit installer signing identifiers, and copies third-party notices. The initial build downloads the pinned Sparkle and mas artifacts; later builds reuse their caches. Python 3 is required on the development machine by these existing resource scripts.
- Local builds use Sign to Run Locally. Select your team and signing identity in Signing & Capabilities for distribution. Hardened runtime is enabled; App Sandbox remains disabled to preserve the application's existing application-scanning and installation capabilities.
- The shared scheme sets `UPOVI_TEST_HOST=1` only for tests. The hosted application uses temporary preferences and skips startup inventory scanning, P2P participation and Sparkle startup. The normal Run action does not set this variable.

## Command-line workflows

```sh
./script/build_and_run.sh --verify
xcodebuild -project Upovi.xcodeproj -scheme Upovi -destination 'platform=macOS' test
xcodebuild -project Upovi.xcodeproj -scheme Upovi -destination 'generic/platform=macOS' \
  -archivePath .build/Upovi.xcarchive archive
```

The run script and `script/package_release.sh` now build through the native Xcode project. The run script stages `dist/Upovi.app`; existing signing, universal-build, alternative-output and notarization environment options remain available. CI runs both XCTest suites through the Xcode scheme.

`Package.swift` retains the original SwiftPM build/test/CLI entrypoints for the diagnostic and acceptance tooling. It uses the same source files and is not needed to open or run the native project. Do not duplicate source implementations between the two build systems. The Sparkle feed scripts resolve SwiftPM's pinned tools on demand if their separate cache is absent.

## Project maintenance

`project.yml` is the reproducible project specification. After changing source membership, targets, schemes or build settings, update the specification and run:

```sh
xcodegen generate
```

Commit the specification and `Upovi.xcodeproj` together. Xcode edits to project settings should also be reflected in `project.yml` before regeneration. User-specific Xcode state is ignored; the shared scheme and package lockfile are checked in.

## Migration validation — 2026-10-26

Validated locally using Xcode 27.1 on Apple Silicon:

- Native Xcode Debug build and both XCTest suites: **173 tests passed**, comprising 156 core tests and 17 application workflow tests. Result bundle: `.local/xcode-migration/Tests.xcresult`.
- The original `swift test` workflow: **173 tests passed**.
- Native Release Archive for **arm64 and x86_64**: succeeded. Archive: `.local/xcode-migration/Upovi.xcarchive`.
- Archived app and all three embedded tools: both architectures present and explicit signing identifiers verified. Deep/strict/all-architectures signature verification passed.
- Both administrator tools correctly refused unprivileged execution. Store bridge version 7.0.0, the app icon, version/build, Sparkle security settings and third-party licenses were checked in the archive.
- `./script/build_and_run.sh --verify`: native Debug build, staging, signing validation and application-process launch verification passed.

These are local development and ad-hoc archive checks. This migration does not establish Developer ID distribution, notarization, actual privileged installation, Intel runtime acceptance or visual acceptance of every application flow. Existing C/Swift compiler warnings are retained; no build errors remain in the final checks.
