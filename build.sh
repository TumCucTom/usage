#!/bin/bash
# Build CCStat.app — a floating always-on-top Claude Code + Codex usage overlay.
# Compiles Sources/main.swift and assembles a self-contained .app bundle with
# agg.py embedded in Resources. Re-run any time to rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/CCStat.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "› cleaning previous bundle"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "› compiling Swift (this can take ~20s)"
swiftc -O \
  -o "$MACOS/CCStat" \
  "$ROOT/Sources/main.swift" \
  -framework AppKit -framework SwiftUI

echo "› embedding aggregator + Info.plist"
cp "$ROOT/agg.py" "$RES/agg.py"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

# ad-hoc sign so macOS lets it run locally without Gatekeeper friction
echo "› ad-hoc code signing"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ built $APP"
echo "  launch with:  open \"$APP\""
