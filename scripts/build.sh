#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/dist/言录.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/KotobaLocal "$APP/Contents/MacOS/KotobaLocal"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
print "已生成：$APP"
