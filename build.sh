#!/bin/zsh
# Сборка MeetRec.app и установщика MeetRec.dmg
#   ./build.sh          — только сборка (build/MeetRec.app + dist/MeetRec.dmg)
#   ./build.sh install  — закрыть приложение, собрать, заменить в /Applications
#                         и запустить заново (безопасно для прав TCC)
set -e
cd "$(dirname "$0")"

MODE="${1:-}"
APP=build/MeetRec.app

# Заменять .app при живом процессе нельзя: macOS заметит подмену бинарника
# и может сбросить выданные права. Режим install закрывает приложение сам.
if [ "$MODE" = "install" ] && pgrep -fq '/Applications/MeetRec.app/Contents/MacOS/MeetRec'; then
  echo "→ Закрываю запущенный MeetRec…"
  osascript -e 'tell application "MeetRec" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -fq '/Applications/MeetRec.app/Contents/MacOS/MeetRec' || break
    sleep 0.5
  done
  if pgrep -fq '/Applications/MeetRec.app/Contents/MacOS/MeetRec'; then
    echo "Ошибка: MeetRec не закрылся (возможно, идёт запись). Установка отменена."
    exit 1
  fi
fi
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

echo "→ Компиляция (swift build)…"
swift build -c release
cp .build/release/MeetRec "$APP/Contents/MacOS/MeetRec"
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/bin/whisper-cli "$APP/Contents/MacOS/whisper-cli"
cp app/bin/llama-server "$APP/Contents/MacOS/llama-server"
cp app/bin/ggml-silero-v5.1.2.bin "$APP/Contents/Resources/ggml-silero-v5.1.2.bin"

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

# Подпись. Требование кода (designated requirement) должно быть стабильным
# между пересборками, иначе macOS считает каждую сборку «другим» приложением
# и сбрасывает выданные права (Запись экрана, Микрофон) в Denied.
# По умолчанию используется самоподписанный сертификат «MeetRec Dev» из
# связки login (создан 2026-07-05, см. DEBUG_JOURNAL.md). Ad-hoc — только
# как крайний fallback: с ним права слетают при каждой пересборке.
SIGN_IDENTITY="${SIGN_IDENTITY:-MeetRec Dev}"
if security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
  echo "→ Подпись ($SIGN_IDENTITY)…"
  codesign --force -s "$SIGN_IDENTITY" \
    -i ru.dinya.meetrec.whisper-cli "$APP/Contents/MacOS/whisper-cli"
  codesign --force -s "$SIGN_IDENTITY" \
    -i ru.dinya.meetrec.llama-server "$APP/Contents/MacOS/llama-server"
  codesign --force -s "$SIGN_IDENTITY" \
    -i ru.dinya.meetrec "$APP"
else
  echo "Внимание: сертификат «$SIGN_IDENTITY» не найден — подпись ad-hoc."
  echo "   Права на запись экрана будут слетать при каждой пересборке!"
  codesign --force -s - -i ru.dinya.meetrec.whisper-cli \
    -r='designated => identifier "ru.dinya.meetrec.whisper-cli"' \
    "$APP/Contents/MacOS/whisper-cli"
  codesign --force -s - -i ru.dinya.meetrec.llama-server \
    -r='designated => identifier "ru.dinya.meetrec.llama-server"' \
    "$APP/Contents/MacOS/llama-server"
  codesign --force -s - -i ru.dinya.meetrec \
    -r='designated => identifier "ru.dinya.meetrec"' \
    "$APP"
fi

echo "→ Установщик DMG…"
DMG_DIR=build/dmg
mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
rm -f dist/MeetRec.dmg
hdiutil create -volname "MeetRec — перетащите в Applications" \
  -srcfolder "$DMG_DIR" -ov -format UDZO dist/MeetRec.dmg >/dev/null
rm -rf "$DMG_DIR" # чтобы Spotlight не находил лишнюю копию приложения

echo "Готово:"
echo "   Приложение: $APP"
echo "   Установщик: dist/MeetRec.dmg"

if [ "$MODE" = "install" ]; then
  echo "→ Установка в /Applications…"
  rm -rf /Applications/MeetRec.app
  cp -R "$APP" /Applications/
  echo "→ Запуск…"
  open /Applications/MeetRec.app
  echo "Установлено и запущено."
else
  echo "Для установки используйте: ./build.sh install"
  echo "   (не заменяйте .app вручную при запущенном приложении)"
fi
