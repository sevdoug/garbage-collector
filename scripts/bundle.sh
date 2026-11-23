#!/bin/bash
# Builds in release mode and assembles "dist/Garbage Collector.app".
# Usage: scripts/bundle.sh [--install]   (--install copies it to /Applications)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Garbage Collector"
EXECUTABLE="GarbageCollector"
BUNDLE_ID="local.garbage-collector"
VERSION="1.0.0"
APP="dist/$APP_NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXECUTABLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The UI strings in the code are English; each .lproj holds one translation.
cp -R Resources/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>To measure how much space the Desktop takes up.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>To measure how much space the Documents folder takes up.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>To measure how much space the Downloads folder takes up.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>To measure the space used on external volumes.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>To measure the space used on network volumes.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. macOS ties privacy permissions to this signature,
# so a new build may ask for Full Disk Access again.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "Done: $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "Installed at /Applications/$APP_NAME.app"
fi
