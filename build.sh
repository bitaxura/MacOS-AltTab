#!/bin/bash
set -e

APP_NAME="TrackpadGestures"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

swiftc \
    -O \
    -import-objc-header Sources/MultitouchBridge.h \
    -F /System/Library/PrivateFrameworks -framework MultitouchSupport \
    -framework Cocoa -framework CoreAudio \
    Sources/main.swift \
    Sources/GestureEngine.swift \
    Sources/WindowEngine.swift \
    Sources/SwitcherPanel.swift \
    Sources/KeyInterceptor.swift \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Built: $APP_BUNDLE"
