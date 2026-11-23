#!/bin/bash
# Compila em release e monta "dist/Garbage Collector.app".
# Uso: scripts/bundle.sh [--install]   (--install copia para /Applications)
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/pt-BR.lproj"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

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
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleLocalizations</key><array><string>pt-BR</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Para medir quanto espaço a Mesa ocupa.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Para medir quanto espaço a pasta Documentos ocupa.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Para medir quanto espaço a pasta Downloads ocupa.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Para medir o espaço ocupado em volumes externos.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Para medir o espaço ocupado em volumes de rede.</string>
</dict>
</plist>
PLIST

# Assinatura ad-hoc: suficiente para rodar localmente. O macOS amarra permissões de privacidade
# a essa assinatura, então um novo build pode pedir o Acesso Total ao Disco de novo.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "Pronto: $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "Instalado em /Applications/$APP_NAME.app"
fi
