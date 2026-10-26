#!/usr/bin/env bash
set -euo pipefail
cd "$SRCROOT"
SOURCE_REVISION="$(git rev-parse HEAD 2>/dev/null || echo source-archive)"
if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  SOURCE_REVISION="$SOURCE_REVISION-dirty"
fi
python3 script/write_bundle_info.py "$DERIVED_FILE_DIR/Upovi-Info.plist" "$SOURCE_REVISION"
