#!/bin/bash
# packaging script to build a standard macOS .app bundle for Whisper GUI

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Whisper GUI"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "=== 1. Creating application bundle structure ==="
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "=== 2. Rebuilding native app executable ==="
./build.sh

echo "=== 3. Copying binary and resources ==="
cp whisper-gui-native "${MACOS_DIR}/${APP_NAME}"
cp speaker_engine.py "${RESOURCES_DIR}/"

echo "=== 4. Creating Info.plist ==="
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.google.whisper-gui</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSContactsUsageDescription</key>
    <string>Whisper GUI requests access to your contacts to associate speaker voice signatures with your contact cards.</string>
</dict>
</plist>
EOF

echo "=== 5. Packaging premium application icons ==="
if [ -f "app_icon.png" ]; then
    ICONSET_DIR="AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"
    
    # Resize PNG to standard apple iconset dimensions
    sips -s format png -z 16 16     app_icon.png --out "${ICONSET_DIR}/icon_16x16.png"
    sips -s format png -z 32 32     app_icon.png --out "${ICONSET_DIR}/icon_16x16@2x.png"
    sips -s format png -z 32 32     app_icon.png --out "${ICONSET_DIR}/icon_32x32.png"
    sips -s format png -z 64 64     app_icon.png --out "${ICONSET_DIR}/icon_32x32@2x.png"
    sips -s format png -z 128 128   app_icon.png --out "${ICONSET_DIR}/icon_128x128.png"
    sips -s format png -z 256 256   app_icon.png --out "${ICONSET_DIR}/icon_128x128@2x.png"
    sips -s format png -z 256 256   app_icon.png --out "${ICONSET_DIR}/icon_256x256.png"
    sips -s format png -z 512 512   app_icon.png --out "${ICONSET_DIR}/icon_256x256@2x.png"
    sips -s format png -z 512 512   app_icon.png --out "${ICONSET_DIR}/icon_512x512.png"
    sips -s format png -z 1024 1024 app_icon.png --out "${ICONSET_DIR}/icon_512x512@2x.png"
    
    # Compile into single .icns file
    iconutil -c icns "${ICONSET_DIR}"
    mv AppIcon.icns "${RESOURCES_DIR}/"
    rm -rf "${ICONSET_DIR}"
    echo "✔ Successfully compiled icons to Resources/AppIcon.icns"
else
    echo "⚠ No app_icon.png found. App bundle will use standard default system icons."
fi

echo "=== 6. Setting executable permissions ==="
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "=== Packaging Complete! ==="
echo "Application bundle created successfully at: $(pwd)/${APP_DIR}"
