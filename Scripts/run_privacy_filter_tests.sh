#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT=".build/privacy-filter-tests"
mkdir -p "$(dirname "$OUT")"

# Compile the real app sources (minus the GUI entry point, which owns the
# top-level code) together with the harness. Keeping this list derived from the
# tree instead of hand-maintained is what stops it going stale as files move.
SOURCES=( $(find Sources/Clipa -name '*.swift' ! -name 'main.swift' | sort) )

# 整库加密（SQLCipher）：与应用同款两步编译——先编 codec 对象，再与 Swift
# 一起链接；模块指向 Vendor/SQLCipher 的头（-I），不再链接系统 libsqlite3。
CIPHER_OBJ="$OUT.o"
clang -c -O1 -target arm64-apple-macosx14.0 -isysroot "$SDK" \
    -DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 \
    -DSQLCIPHER_CRYPTO_CC -DSQLITE_ENABLE_FTS5 \
    -I Vendor/SQLCipher Vendor/SQLCipher/sqlite3.c \
    -o "$CIPHER_OBJ"

xcrun swiftc -swift-version 5 -sdk "$SDK" \
    -Xcc -DSQLITE_HAS_CODEC \
    -I Vendor/SQLCipher \
    "${SOURCES[@]}" \
    Scripts/PrivacyFilterTests/main.swift \
    "$CIPHER_OBJ" \
    -o "$OUT" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework Security \
    -framework ServiceManagement \
    -framework ApplicationServices \
    -framework LocalAuthentication

"$OUT"
