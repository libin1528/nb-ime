#!/bin/zsh
# 编译并装到 ~/Applications/NB 输入法.app。
# 签名：有 sign-identity.local（一行，钥匙串里证书的名字，不进仓库）就用它，重编后辅助功能授权不会失效；
# 没有就用临时签名（-），能跑，但每次重编都要重新在「辅助功能」里打开一次。
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
SIGN_ID="-"
[[ -f sign-identity.local ]] && SIGN_ID="$(<sign-identity.local)"
codesign --force --sign "$SIGN_ID" "$APP"
echo "装好了：$APP"
if [[ " $* " != *" --no-run "* ]]; then open "$APP"; fi
