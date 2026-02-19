#!/bin/bash
set -euo pipefail

APP_NAME="Pane"
BUNDLE_ID="com.ben.pane"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building ${APP_NAME} (release)..."
cd "$SCRIPT_DIR"
swift build -c release -q

# Kill running instance so macOS doesn't invalidate the code signature
pkill -9 Mockup 2>/dev/null || true
sleep 0.5

echo "Assembling app bundle..."
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

cp -f ".build/arm64-apple-macosx/release/$APP_NAME" "$CONTENTS/MacOS/Mockup"

# Resource bundle (contains icon + logo)
BUNDLE_SRC=".build/arm64-apple-macosx/release/Pane_Pane.bundle"
if [ -d "$BUNDLE_SRC" ]; then
    cp -Rf "$BUNDLE_SRC" "$CONTENTS/Resources/"
fi

# Top-level icon for Finder/Launchpad
if [ -f "Sources/AppIcon.icns" ]; then
    cp -f "Sources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Mockup</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

echo "Installed to $APP_DIR"
