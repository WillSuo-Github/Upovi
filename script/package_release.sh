#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VERSION="0.3.2"
BUILD="5"
SOURCE_REVISION="$(git rev-parse HEAD 2>/dev/null || echo source-archive)"
if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then SOURCE_REVISION="$SOURCE_REVISION-dirty"; fi
CONFIGURATION="${CONFIGURATION:-release}"
SIGNING_IDENTITY="${UPOVI_SIGNING_IDENTITY:--}"
OUTPUT_DIR="${UPOVI_OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$OUTPUT_DIR/Upovi.app"
if [[ -f "$APP_BUNDLE/Contents/MacOS/Upovi" ]] && /usr/sbin/lsof -t "$APP_BUNDLE/Contents/MacOS/Upovi" >/dev/null 2>&1; then
  echo "Quit the running Upovi build before replacing its signed bundle." >&2
  exit 2
fi
if [[ "${UPOVI_UNIVERSAL:-0}" == "1" ]]; then
  swift build -c "$CONFIGURATION" --product Upovi --arch arm64 --arch x86_64
  BINARY_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c "$CONFIGURATION" --product Upovi
  BINARY_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_DIR/Upovi" "$APP_BUNDLE/Contents/MacOS/Upovi"
cp Resources/Upovi.icns "$APP_BUNDLE/Contents/Resources/Upovi.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Upovi</string>
<key>CFBundleIdentifier</key><string>app.upovi.Upovi</string>
<key>CFBundleName</key><string>Upovi</string>
<key>CFBundleDisplayName</key><string>Upovi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>UpoviSourceRevision</key><string>$SOURCE_REVISION</string>
<key>CFBundleIconFile</key><string>Upovi</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Discover opted-in peers and exchange selected app version reports.</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Upovi contributors. MIT License.</string>
</dict></plist>
PLIST
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP_BUNDLE"
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --strict --all-architectures "$APP_BUNDLE"
if [[ "${UPOVI_STAGE_ONLY:-0}" == "1" ]]; then echo "Staged: $APP_BUNDLE"; exit 0; fi
ARCHIVE="$OUTPUT_DIR/Upovi-$VERSION.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"
if [[ -n "${UPOVI_NOTARY_PROFILE:-}" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then echo "Notarization requires a Developer ID signature." >&2; exit 2; fi
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$UPOVI_NOTARY_PROFILE" --wait --output-format json > "$OUTPUT_DIR/notarization.json"
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted"' "$OUTPUT_DIR/notarization.json"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  spctl --assess --type execute -vv "$APP_BUNDLE"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"
fi
(cd "$OUTPUT_DIR" && shasum -a 256 "Upovi-$VERSION.zip" > "Upovi-$VERSION.zip.sha256")
echo "Packaged: $ARCHIVE"
