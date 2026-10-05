#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="1.0.0"
APP_NAME="Clipa"
BUILD_DIR=".build/app"
STAGE_DIR=".build/dmg-staging"
ICONSET="$BUILD_DIR/AppIcon.iconset"

echo "==> 清理旧构建"
rm -rf "$BUILD_DIR" "$STAGE_DIR" dist
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/Resources"
mkdir -p "$ICONSET"
mkdir -p dist

echo "==> 编译 SQLCipher（codec 编进二进制，自包含）"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
# SQLCipher 合并源码单独用 clang 编（codec 宏必须直接传给 C 编译器，
# -Xcc 不会传导到 swiftc 的 C 编译步骤——2026-10-04 实测踩过）。
clang -c -O2 -target arm64-apple-macosx14.0 -isysroot "$SDK" \
    -DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 \
    -DSQLCIPHER_CRYPTO_CC -DSQLITE_ENABLE_FTS5 \
    -I Vendor/SQLCipher Vendor/SQLCipher/sqlite3.c \
    -o "$BUILD_DIR/sqlite3-cipher.o"

echo "==> 编译（arm64，macOS 14+，链接 SQLCipher）"
SOURCES=( $(find Sources/Clipa -name '*.swift' | sort) )
xcrun swiftc -O -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    -sdk "$SDK" \
    -Xcc -DSQLITE_HAS_CODEC \
    -I Vendor/SQLCipher \
    "${SOURCES[@]}" \
    "$BUILD_DIR/sqlite3-cipher.o" \
    -o "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework Security \
    -framework ServiceManagement \
    -framework ApplicationServices \
    -framework LocalAuthentication

echo "==> 生成图标"
swift Scripts/generate_icon.swift "$BUILD_DIR/icon1024.png"
sips -z 16 16 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$BUILD_DIR/icon1024.png" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$BUILD_DIR/icon1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"

echo "==> 组装 App"
cp Support/Info.plist "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 15" \
    "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist" >/dev/null

echo "==> 组装 CLI 助手（clipa）"
# `clipa` 是主二进制的一个**副本**：以这个名字被调用时，它走 CLI 客户端分支，
# 不启动 GUI。用副本而不是符号链接，是为了让下面的 `codesign --deep` 一并覆盖它。
#
# 放 `Contents/Helpers/` 而不是 `Contents/MacOS/`：macOS 的默认文件系统**大小写不敏感**，
# `clipa` 和 `Clipa` 会被当成同一个名字，兄弟副本直接 cp 失败（实测踩过）。
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/Helpers"
cp "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    "$BUILD_DIR/$APP_NAME.app/Contents/Helpers/clipa"

# `clipa-mcp` 同理：MCP stdio 薄壳，给 Claude Code / Cursor 等 AI 工具当服务器。
# 同一个二进制、按名字路由 —— 薄壳里没有任何第二套策略可藏。
cp "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    "$BUILD_DIR/$APP_NAME.app/Contents/Helpers/clipa-mcp"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"
codesign --verify --verbose=2 "$BUILD_DIR/$APP_NAME.app"

echo "==> 制作 DMG"
mkdir -p "$STAGE_DIR"
cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGE_DIR/"
cp README.md "$STAGE_DIR/使用说明.md"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "dist/$APP_NAME-$VERSION.dmg" >/dev/null
hdiutil verify "dist/$APP_NAME-$VERSION.dmg"

echo ""
echo "==> 完成"
echo "App: $BUILD_DIR/$APP_NAME.app"
echo "DMG: dist/$APP_NAME-$VERSION.dmg"
