#!/bin/zsh
set -euo pipefail

# Only isolated fixtures; does not package, install or read the user's database/keychain.
cd "$(dirname "$0")/.."
CHECK_DIR=".build/storage-search-checks"
mkdir -p "$CHECK_DIR"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
clang -c -O2 -target arm64-apple-macosx14.0 -isysroot "$SDK" \
    -DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 -DSQLCIPHER_CRYPTO_CC \
    -DSQLITE_ENABLE_FTS5 -I Vendor/SQLCipher Vendor/SQLCipher/sqlite3.c \
    -o "$CHECK_DIR/sqlite3-cipher.o"
SOURCES=( ${(f)"$(rg --files --no-ignore Sources/Clipa -g '*.swift' | sort)"} )
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
    -sdk "$SDK" -Xcc -DSQLITE_HAS_CODEC -I Vendor/SQLCipher \
    "${SOURCES[@]}" "$CHECK_DIR/sqlite3-cipher.o" -o "$CHECK_DIR/Clipa" \
    -framework AppKit -framework SwiftUI -framework Carbon \
    -framework Security -framework ServiceManagement \
    -framework ApplicationServices -framework LocalAuthentication
for probe in selftest storage-search-probe api-probe async-store-probe search-parity; do
    "$CHECK_DIR/Clipa" "--$probe" > "$CHECK_DIR/$probe.log" 2>&1 || {
        cat "$CHECK_DIR/$probe.log"
        exit 1
    }
    tail -1 "$CHECK_DIR/$probe.log"
done
"$CHECK_DIR/Clipa" --search-recall-audit --synthetic > "$CHECK_DIR/search-recall.log" 2>&1 || {
    cat "$CHECK_DIR/search-recall.log"
    exit 1
}
tail -1 "$CHECK_DIR/search-recall.log"
"$CHECK_DIR/Clipa" --storage-search-bench | tee "$CHECK_DIR/benchmark.log"
