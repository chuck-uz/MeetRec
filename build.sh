#!/bin/zsh
# Сборка MeetRec.app и установщика MeetRec.dmg
set -e
cd "$(dirname "$0")"

APP=build/MeetRec.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

echo "→ Компиляция (swift build)…"
swift build -c release
cp .build/release/MeetRec "$APP/Contents/MacOS/MeetRec"
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/bin/whisper-cli "$APP/Contents/MacOS/whisper-cli"

echo "→ Иконка…"
if [ ! -f app/AppIcon.icns ]; then
  swift app/make-icon.swift build/AppIcon.png
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d build/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o app/AppIcon.icns
fi
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Подпись (ad-hoc)…"
codesign --force -s - "$APP/Contents/MacOS/whisper-cli"
codesign --force --deep -s - "$APP"

echo "→ Установщик DMG…"
DMG_DIR=build/dmg
mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
rm -f dist/MeetRec.dmg
hdiutil create -volname "MeetRec — перетащите в Applications" \
  -srcfolder "$DMG_DIR" -ov -format UDZO dist/MeetRec.dmg >/dev/null
rm -rf "$DMG_DIR" # чтобы Spotlight не находил лишнюю копию приложения

echo "✅ Готово:"
echo "   Приложение: $APP"
echo "   Установщик: dist/MeetRec.dmg"
