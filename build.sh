#!/bin/zsh
# 编译并装到 ~/Applications/ITX Voice.app。用固定的开发证书签名，重编后辅助功能授权不会失效。
set -euo pipefail
cd "${0:A:h}"
APP="$HOME/Applications/ITX Voice.app"
mkdir -p build
swiftc -O -swift-version 5 -o build/ITXVoice Sources/main.swift
pkill -x ITXVoice 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp build/ITXVoice "$APP/Contents/MacOS/ITXVoice"
codesign --force --sign "Apple Development: bin li (RX5PHB34BJ)" "$APP"
echo "装好了：$APP"
