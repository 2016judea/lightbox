#!/bin/bash
# Builds build/Lightbox.app (and copies it to /Applications with --install).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SANE="${LIGHTBOX_SANE:-$HOME/Library/Lightbox/sane}"
[ -x "$SANE/bin/scanimage" ] || scripts/build_sane.sh
# a fresh build every time: the Xcode build system has reported "up to date" over edited sources here
rm -rf .build
swift build -c release --build-system native
APP=build/Lightbox.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Lightbox "$APP/Contents/MacOS/Lightbox"
cp assets/Lightbox.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Lightbox</string>
  <key>CFBundleDisplayName</key><string>Lightbox</string>
  <key>CFBundleIdentifier</key><string>dev.aidanjude.lightbox</string>
  <key>CFBundleExecutable</key><string>Lightbox</string>
  <key>CFBundleIconFile</key><string>Lightbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPhotoLibraryUsageDescription</key><string>Lightbox looks for the lab scan of the frame you just scanned, so you can compare against it.</string>
  <key>NSAppleEventsUsageDescription</key><string>Lightbox adds your scans to the Film album in Photos.</string>
  <key>LBSanePrefix</key><string>$SANE</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $ROOT/$APP"
if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Lightbox.app && cp -R "$APP" /Applications/ && echo "installed /Applications/Lightbox.app"
fi
