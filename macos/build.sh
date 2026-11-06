#!/bin/bash
# Сборка «Кто там» в ~/Applications/ade_ktotam.app (без Xcode, только Command Line Tools).
set -e
cd "$(dirname "$0")"
mkdir -p build tools
# Обход бага CLT 16: модуль SwiftBridging объявлен дважды — прячем лишний modulemap через VFS-оверлей.
: > tools/empty.modulemap
cat > tools/vfs.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "/Library/Developer/CommandLineTools/usr/include/swift", "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$PWD/tools/empty.modulemap" } ] } ] }
YAML
OPT=${OPT:--O}
swiftc $OPT -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
  -Xcc -ivfsoverlay -Xcc "$PWD/tools/vfs.yaml" -vfsoverlay "$PWD/tools/vfs.yaml" \
  -module-cache-path build/ModuleCache \
  Sources/Ktotam/*.swift -o build/Ktotam

[ "$1" = "--bin-only" ] && exit 0

APP="build/ade_ktotam.app"
DEST="${DEST:-$HOME/Applications}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Ktotam "$APP/Contents/MacOS/Ktotam"
cp Info.plist "$APP/Contents/Info.plist"
# Иконка в стиле ADE (белая плашка, логотип, подпись, зелёная полоса)
# плюс значок Face ID — tools/mkicon_ktotam.m
if [ ! -f build/AppIcon.icns ] || [ tools/mkicon_ktotam.m -nt build/AppIcon.icns ]; then
  clang -fobjc-arc -framework Cocoa tools/mkicon_ktotam.m -o build/mkicon_ktotam
  rm -rf build/AppIcon.iconset
  build/mkicon_ktotam ~/Documents/ade_icons/logo.svg "кто там" build/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP" >/dev/null 2>&1

mkdir -p "$DEST"
rm -rf "$DEST/ade_ktotam.app"
# Переносим, а не копируем: иначе Launchpad и Spotlight видят две копии приложения.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREG -u "$PWD/$APP" >/dev/null 2>&1 || true
mv "$APP" "$DEST/"
$LSREG -f "$DEST/ade_ktotam.app" >/dev/null 2>&1 || true
touch "$DEST/ade_ktotam.app"
echo "Готово: $DEST/ade_ktotam.app"
