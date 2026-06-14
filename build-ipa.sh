#!/usr/bin/env bash
# build-ipa.sh — собрать голый (unsigned) .ipa WhitelistChecker.
# Подпись делается отдельно (Sideloadly / Feather / Gbox).
set -euo pipefail

cd "$(dirname "$0")"
PROJ=WhitelistChecker.xcodeproj
SCHEME=WhitelistChecker
APP_NAME=WhitelistChecker
OUT=dist

echo "▶ Сборка под iphoneos без подписи…"
rm -rf build
xcodebuild -project "$PROJ" -scheme "$SCHEME" \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build | tail -3

APP="build/Build/Products/Release-iphoneos/${APP_NAME}.app"
[ -d "$APP" ] || { echo "✗ .app не найден: $APP"; exit 1; }

echo "▶ Упаковка в .ipa…"
WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
mkdir -p "$OUT"
rm -f "$OUT/${APP_NAME}-unsigned.ipa"
( cd "$WORK" && zip -qr "$OLDPWD/$OUT/${APP_NAME}-unsigned.ipa" Payload )
rm -rf "$WORK"

echo "✓ Готово: $OUT/${APP_NAME}-unsigned.ipa"
ls -la "$OUT/${APP_NAME}-unsigned.ipa"
echo
echo "Дальше: подпиши .ipa в Sideloadly / Feather / Gbox своим сертификатом и поставь на устройство."
echo "ВАЖНО: тестировать на реальном телефоне в мобильной сети (симулятор шейп не покажет)."
