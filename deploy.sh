#!/bin/bash

APP_NAME="HyperWM"
APP_PATH="$HOME/Applications/$APP_NAME.app"
BUNDLE_ID="com.hyperwm.app"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$PROJECT_DIR"

# Build
echo "Building..."
swift build -c release 2>&1
if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Bundle
mkdir -p "$APP_PATH/Contents/MacOS"
cp .build/release/$APP_NAME "$APP_PATH/Contents/MacOS/"

cat > "$APP_PATH/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Sign
codesign --force --deep --sign - "$APP_PATH" 2>/dev/null

echo "Deployed to $APP_PATH"

# Restart if -r flag
if [ "$1" = "-r" ]; then
    pkill -f "$APP_NAME" 2>/dev/null
    sleep 0.5
    open "$APP_PATH"
    echo "Restarted"
fi
