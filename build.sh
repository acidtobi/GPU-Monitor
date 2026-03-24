#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building..."
swift build -c release 2>&1

BINARY=".build/release/GPUMonitor"
APP="GPUMonitor.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Packaging $APP..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BINARY" "$MACOS/GPUMonitor"

# Build .icns from Assets.xcassets icon PNGs
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET_DIR"
ICON_SRC="Sources/GPUMonitor/Assets.xcassets/AppIcon.appiconset"
cp "$ICON_SRC/icon_16.png"   "$ICONSET_DIR/icon_16x16.png"
cp "$ICON_SRC/icon_32.png"   "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICON_SRC/icon_32.png"   "$ICONSET_DIR/icon_32x32.png"
cp "$ICON_SRC/icon_64.png"   "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICON_SRC/icon_128.png"  "$ICONSET_DIR/icon_128x128.png"
cp "$ICON_SRC/icon_256.png"  "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICON_SRC/icon_256.png"  "$ICONSET_DIR/icon_256x256.png"
cp "$ICON_SRC/icon_512.png"  "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICON_SRC/icon_512.png"  "$ICONSET_DIR/icon_512x512.png"
cp "$ICON_SRC/icon_1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.local.GPUMonitor</string>
    <key>CFBundleName</key>
    <string>GPUMonitor</string>
    <key>CFBundleExecutable</key>
    <string>GPUMonitor</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
EOF

echo "Done. Run with:"
echo "  open $SCRIPT_DIR/$APP"
