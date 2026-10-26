#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
OUTPUT_DIR="${UPOVI_OUTPUT_DIR:-$ROOT_DIR/dist}"
VERSION="$(python3 -c 'import json; print(json.load(open("Resources/Release.json"))["version"])')"
ACCOUNT="$(python3 -c 'import json; print(json.load(open("Resources/Release.json"))["keychainAccount"])')"
PUBLIC_KEY="$(python3 -c 'import json; print(json.load(open("Resources/Release.json"))["publicEDKey"])')"
TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$TOOLS/generate_appcast" ]]; then swift package resolve; fi
ACTUAL_KEY="$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)"
if [[ "$ACTUAL_KEY" != "$PUBLIC_KEY" ]]; then echo "Sparkle signing key does not match Release.json." >&2; exit 2; fi
ARCHIVE="$OUTPUT_DIR/Upovi-$VERSION.zip"
if [[ ! -f "$ARCHIVE" ]]; then echo "Build the signed release archive first." >&2; exit 2; fi
FEED_DIR="$OUTPUT_DIR/update-feed"
mkdir -p "$FEED_DIR"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.update-feed.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp "$ARCHIVE" "$STAGING_DIR/"
"$TOOLS/generate_appcast" --account "$ACCOUNT" --download-url-prefix "https://github.com/WillSuo-Github/Upovi/releases/download/v$VERSION/" "$STAGING_DIR"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$STAGING_DIR/appcast.xml"
cp "$STAGING_DIR/appcast.xml" "$FEED_DIR/appcast.xml"
cp "$ARCHIVE" "$FEED_DIR/"
echo "Prepared signed feed: $FEED_DIR/appcast.xml"
echo "Publish appcast.xml and Upovi-$VERSION.zip together in release v$VERSION after acceptance."
