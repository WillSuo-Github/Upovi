#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
OUTPUT_DIR="${UPOVI_OUTPUT_DIR:-$ROOT_DIR/dist}"
ARCHIVE_NAME="$(python3 script/release_metadata.py show --field archive)"
RELEASE_TAG="$(python3 script/release_metadata.py show --field tag)"
DOWNLOAD_PREFIX="$(python3 script/release_metadata.py show --field download-prefix)"
ACCOUNT="$(python3 -c 'import json; print(json.load(open("Resources/Release.json"))["keychainAccount"])')"
PUBLIC_KEY="$(python3 -c 'import json; print(json.load(open("Resources/Release.json"))["publicEDKey"])')"
TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$TOOLS/generate_appcast" ]]; then swift package resolve; fi
ACTUAL_KEY="$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)"
if [[ "$ACTUAL_KEY" != "$PUBLIC_KEY" ]]; then echo "Sparkle signing key does not match Release.json." >&2; exit 2; fi
ARCHIVE="$OUTPUT_DIR/$ARCHIVE_NAME"
if [[ ! -f "$ARCHIVE" ]]; then echo "Build the signed release archive first." >&2; exit 2; fi
FEED_DIR="$OUTPUT_DIR/update-feed"
mkdir -p "$FEED_DIR"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.update-feed.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp "$ARCHIVE" "$STAGING_DIR/"
"$TOOLS/generate_appcast" --account "$ACCOUNT" --download-url-prefix "$DOWNLOAD_PREFIX" "$STAGING_DIR"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$STAGING_DIR/appcast.xml"
cp "$STAGING_DIR/appcast.xml" "$FEED_DIR/appcast.xml"
cp "$ARCHIVE" "$FEED_DIR/"
echo "Prepared signed feed: $FEED_DIR/appcast.xml"
echo "Publish appcast.xml and $ARCHIVE_NAME together in release $RELEASE_TAG after acceptance."
