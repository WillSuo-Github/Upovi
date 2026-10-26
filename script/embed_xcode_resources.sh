#!/usr/bin/env bash
set -euo pipefail
cd "$SRCROOT"
APP_BUNDLE="$TARGET_BUILD_DIR/$WRAPPER_NAME"
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$SIGNING_IDENTITY" ]]; then SIGNING_IDENTITY="-"; fi
python3 script/embed_store_bridge.py "$APP_BUNDLE" "$SIGNING_IDENTITY"
# Mach-O command-line tools do not carry an Info.plist bundle identifier.
# Their explicit signing identities are checked by administrator authorization.
for HELPER_NAME in UpoviInstaller UpoviStoreInstaller; do
  case "$HELPER_NAME" in
    UpoviInstaller) HELPER_ID=app.upovi.Installer ;;
    UpoviStoreInstaller) HELPER_ID=app.upovi.StoreInstaller ;;
  esac
  SIGNING_ARGS=(--force --identifier "$HELPER_ID" --sign "$SIGNING_IDENTITY")
  if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGNING_ARGS+=(--options runtime --timestamp); fi
  /usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP_BUNDLE/Contents/MacOS/$HELPER_NAME"
done
# Keep the pinned license independent of Xcode's build/archive package-cache layout.
cp Vendor/Sparkle-LICENSE "$APP_BUNDLE/Contents/Resources/Sparkle-LICENSE"
