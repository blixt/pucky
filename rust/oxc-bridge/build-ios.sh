#!/bin/bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_NAME="liboxc_bridge"

cd "$CRATE_DIR"

echo "Building for iOS device (aarch64-apple-ios)..."
cargo build --release --target aarch64-apple-ios

echo "Building for iOS simulator (aarch64-apple-ios-sim)..."
cargo build --release --target aarch64-apple-ios-sim

echo "Creating XCFramework..."
rm -rf "$CRATE_DIR/OxcBridge.xcframework"
xcodebuild -create-xcframework \
    -library "target/aarch64-apple-ios/release/${LIB_NAME}.a" \
    -headers include/ \
    -library "target/aarch64-apple-ios-sim/release/${LIB_NAME}.a" \
    -headers include/ \
    -output "$CRATE_DIR/OxcBridge.xcframework"

echo "Done! Built OxcBridge.xcframework"
ls -la "$CRATE_DIR/OxcBridge.xcframework/"
