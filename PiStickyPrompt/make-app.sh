#!/bin/bash
# Build PiStickyPrompt via SwiftPM and wrap it into a .app bundle.
#
# Usage:  ./make-app.sh           # release build, .app placed alongside script
#         ./make-app.sh debug     # debug build
#         ./make-app.sh release ~/Applications   # custom destination dir
set -euo pipefail

CONFIG="${1:-release}"
DEST_DIR="${2:-$(cd "$(dirname "$0")" && pwd)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "config must be 'debug' or 'release'" >&2
    exit 2
fi

cd "$HERE"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/PiStickyPrompt"
if [[ ! -x "$BIN" ]]; then
    echo "binary not found at $BIN" >&2
    exit 1
fi

APP="$DEST_DIR/PiStickyPrompt.app"
echo "==> packaging into $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/PiStickyPrompt"
chmod +x "$APP/Contents/MacOS/PiStickyPrompt"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PiStickyPrompt</string>
  <key>CFBundleDisplayName</key><string>Pi Sticky Prompt</string>
  <key>CFBundleIdentifier</key><string>org.pi.sticky-prompt</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>PiStickyPrompt</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Ad-hoc sign so macOS will run it locally without "damaged" warnings.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> done: $APP"
echo "    open $APP   # to launch"
