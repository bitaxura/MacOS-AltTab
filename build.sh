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
    Sources/ActionPoster.swift \
    Sources/ScrollRemapper.swift \
    Sources/WindowEngine.swift \
    Sources/WindowPreview.swift \
    Sources/SwitcherPanel.swift \
    Sources/SwitcherController.swift \
    Sources/KeyInterceptor.swift \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Ad-hoc sign so Accessibility/Input Monitoring permissions stick across rebuilds.
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Built: $APP_BUNDLE"
echo "Next: drag it to /Applications, then see README.md for permissions."
