#!/bin/bash
# 编译并打包成可双击运行的 nvpeek.app
set -euo pipefail
cd "$(dirname "$0")"

# 说明：命令行工具自带的最新 27.0 SDK 把 SwiftUI 的 @State 改成了宏实现，
# 但宏插件没有随命令行工具一起发布，会编译报错；固定用 26.5 SDK 编译即可，
# 编出来的程序在更高版本的 macOS 上照常运行。
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

echo "==> 编译中…"
if [ -d "$SDK" ]; then
    swift build -c release --sdk "$SDK"
else
    swift build -c release
fi

echo "==> 校验解析逻辑…"
swiftc -sdk "$SDK" -o /tmp/nvpeek_verify \
    Sources/nvpeekCore/Models.swift Sources/nvpeekCore/Parser.swift \
    Sources/nvpeekCore/SSHRunner.swift Sources/nvpeekCore/Persistence.swift \
    Sources/nvpeekCore/SSHConfig.swift \
    Sources/nvpeekCore/MonitorStore.swift Tests/ManualCheck/main.swift
/tmp/nvpeek_verify

echo "==> 打包…"
APP="build/nvpeek.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/nvpeek "$APP/Contents/MacOS/nvpeek"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 本地临时签名（不发布 App Store 也需要）
codesign --force --sign - "$APP"

echo "✅ 构建完成：$(pwd)/$APP"
echo "   双击运行，或在终端执行：open $(pwd)/$APP"
