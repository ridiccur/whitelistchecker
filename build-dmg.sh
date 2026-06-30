#!/usr/bin/env bash
# build-dmg.sh — собрать macOS-приложение (Mac Catalyst, Apple Silicon) и упаковать в .dmg.
# Подпись ad-hoc: приложение запускается, но при скачивании из сети Gatekeeper
# поставит карантин — снять командой  xattr -dr com.apple.quarantine /Applications/WhitelistChecker.app
set -euo pipefail

cd "$(dirname "$0")"
PROJ=WhitelistChecker.xcodeproj
SCHEME=WhitelistChecker
APP_NAME=WhitelistChecker
OUT=dist
VOL="WL Checker"

echo "▶ Сборка под Mac Catalyst (arm64) без подписи…"
rm -rf build-mac
if ! xcodebuild -project "$PROJ" -scheme "$SCHEME" \
  -configuration Release -derivedDataPath build-mac \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  SUPPORTS_MACCATALYST=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > build-mac.log 2>&1; then
  echo "✗ Сборка упала. Диагностика:"
  grep -nE "error:|error |actool|AppIcon|asset|\.png|The following build commands failed" build-mac.log | tail -60 || true
  echo "--- последние 60 строк лога ---"
  tail -60 build-mac.log
  exit 1
fi
tail -3 build-mac.log

APP="build-mac/Build/Products/Release-maccatalyst/${APP_NAME}.app"
[ -d "$APP" ] || { echo "✗ .app не найден: $APP"; exit 1; }

# --- штамп сборки: монотонный build-номер + человекочитаемая дата (как в .ipa) ---
BN_FILE=".build-number"
if [ -n "${WLC_BUILD_NUMBER:-}" ]; then
  BUILD_NUM="$WLC_BUILD_NUMBER"
else
  BUILD_NUM=$(( $(cat "$BN_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$BUILD_NUM" > "$BN_FILE"
fi
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleVersion $BUILD_NUM" "$APP/Contents/Info.plist"
"$PB" -c "Add :WLCBuildDate string $BUILD_DATE" "$APP/Contents/Info.plist" 2>/dev/null \
  || "$PB" -c "Set :WLCBuildDate $BUILD_DATE" "$APP/Contents/Info.plist"
echo "▶ Штамп сборки: build $BUILD_NUM · $BUILD_DATE"

# Ad-hoc подпись: иначе после правки Info.plist подпись битая и приложение не стартует.
echo "▶ Ad-hoc подпись…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "▶ Сборка .dmg…"
mkdir -p "$OUT"
DMG="$OUT/${APP_NAME}.dmg"
rm -f "$DMG"

# Фон окна .dmg: берём готовые PNG из assets/dmg (если нет — генерим Swift'ом).
BG_DIR="assets/dmg"
if [ ! -f "$BG_DIR/background.png" ] && [ -f "$BG_DIR/make-background.swift" ]; then
  echo "▶ Генерация фона .dmg…"
  swift "$BG_DIR/make-background.swift" "$BG_DIR/background.png" "$BG_DIR/background@2x.png" || true
fi

# Оформление .dmg делает dmgbuild — pure-Python, пишет .DS_Store напрямую
# (фон + позиции иконок + размер окна), БЕЗ Finder/AppleScript. Поэтому работает
# и в headless CI, и при тёмной теме локально, где ос'script-подход не сохраняет фон.
# dmgbuild ставим в изолированный venv, чтобы не трогать системный python.
make_styled_dmg() {
  local venv=.dmgvenv
  if [ ! -x "$venv/bin/dmgbuild" ]; then
    echo "▶ Установка dmgbuild (venv)…"
    python3 -m venv "$venv" >/dev/null 2>&1 || return 1
    "$venv/bin/pip" install --quiet --upgrade pip dmgbuild >/dev/null 2>&1 || return 1
  fi
  "$venv/bin/dmgbuild" -s "$BG_DIR/dmg-settings.py" \
    -D app="$APP" -D bg="$BG_DIR/background.png" \
    "$VOL" "$DMG" >/dev/null 2>&1
}

make_plain_dmg() {
  local stage; stage="$(mktemp -d)"
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "$VOL" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$stage"
}

if make_styled_dmg && [ -f "$DMG" ]; then
  echo "  ✓ оформленный .dmg (фон + раскладка через dmgbuild)"
else
  echo "  ⚠ dmgbuild недоступен — собираю простой .dmg"
  rm -f "$DMG"
  make_plain_dmg
fi

echo "✓ Готово: $OUT/${APP_NAME}.dmg"
ls -la "$OUT/${APP_NAME}.dmg"
echo
echo "Установка: открыть .dmg, перетащить WhitelistChecker в Applications."
echo "Первый запуск (приложение не подписано Apple ID):"
echo "  xattr -dr com.apple.quarantine /Applications/WhitelistChecker.app"
echo "  затем открыть как обычно (или ПКМ → «Открыть»)."
