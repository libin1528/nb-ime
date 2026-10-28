#!/bin/zsh
# 编译并装到 ~/Applications/NB 输入法.app。用固定的开发证书签名，重编后辅助功能授权不会失效。
# ./build.sh            编译、装好、启动
# ./build.sh --no-run   只编译、装好（截图测试时用，免得和正在跑的那份抢热键）
# ./build.sh --icon     顺便重画 AppIcon.icns
set -euo pipefail
cd "${0:A:h}"
APP="$HOME/Applications/NB 输入法.app"
mkdir -p build
if [[ " $* " == *" --icon "* || ! -f AppIcon.icns ]]; then
  swiftc -O Sources/Glyph.swift IconTool/main.swift -o build/make_icon
  build/make_icon
fi
swiftc -O -swift-version 5 -o build/NBIME Sources/*.swift
if [[ " $* " != *" --no-run "* ]]; then pkill -x NBIME 2>/dev/null || true; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp build/NBIME "$APP/Contents/MacOS/NBIME"
codesign --force --sign "Apple Development: bin li (RX5PHB34BJ)" "$APP"
echo "装好了：$APP"
if [[ " $* " != *" --no-run "* ]]; then open "$APP"; fi
