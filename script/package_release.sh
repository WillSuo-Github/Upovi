#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VERSION="$(python3 -c 'import json; print(json.load(open("Resources/Release.json"))["version"])')"
CONFIGURATION="${CONFIGURATION:-release}"
case "$CONFIGURATION" in
  debug|Debug) CONFIGURATION=Debug ;;
  release|Release) CONFIGURATION=Release ;;
  *) echo "Unsupported configuration: $CONFIGURATION" >&2; exit 2 ;;
esac
SIGNING_IDENTITY="${UPOVI_SIGNING_IDENTITY:--}"
OUTPUT_DIR="${UPOVI_OUTPUT_DIR:-$ROOT_DIR/dist}"
DERIVED_DATA="${UPOVI_DERIVED_DATA:-$ROOT_DIR/.build/XcodeDerivedData}"
APP_BUNDLE="$OUTPUT_DIR/Upovi.app"
if [[ -f "$APP_BUNDLE/Contents/MacOS/Upovi" ]] && /usr/sbin/lsof -t "$APP_BUNDLE/Contents/MacOS/Upovi" >/dev/null 2>&1; then
  echo "Quit the running Upovi build before replacing its signed bundle." >&2
  exit 2
fi
BUILD_SETTINGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
if [[ "${UPOVI_UNIVERSAL:-0}" == "1" ]]; then
  BUILD_SETTINGS+=(ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64')
else
  BUILD_SETTINGS+=(ONLY_ACTIVE_ARCH=YES "ARCHS=$(uname -m)")
fi
xcodebuild -project Upovi.xcodeproj -scheme Upovi -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" \
  "${BUILD_SETTINGS[@]}" build
mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$DERIVED_DATA/Build/Products/$CONFIGURATION/Upovi.app" "$APP_BUNDLE"
codesign --verify --deep --strict --all-architectures "$APP_BUNDLE"
if [[ "${UPOVI_STAGE_ONLY:-0}" == "1" ]]; then echo "Staged: $APP_BUNDLE"; exit 0; fi
python3 - "$APP_BUNDLE/Contents/Info.plist" <<'PY'
import json, plistlib, sys
with open('Resources/Release.json') as handle:
    release = json.load(handle)
with open(sys.argv[1], 'rb') as handle:
    info = plistlib.load(handle)
if (info['CFBundleShortVersionString'], info['CFBundleVersion']) != (release['version'], release['build']):
    raise SystemExit('Synchronize Xcode version/build settings with Resources/Release.json before packaging a release.')
PY
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
