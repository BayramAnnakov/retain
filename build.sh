#!/bin/bash
# Build script for Retain - ensures app bundle is created correctly with icon

set -e

echo "Building Retain..."
swift build -c release

echo "Creating app bundle..."
rm -rf dist
mkdir -p dist/Retain.app/Contents/MacOS
mkdir -p dist/Retain.app/Contents/Resources

# Copy binary
cp .build/release/Retain dist/Retain.app/Contents/MacOS/

# Generate Info.plist (always enforce bundle identifier)
cat > dist/Retain.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Retain</string>
    <key>CFBundleIdentifier</key>
    <string>com.empatika.Retain</string>
    <key>CFBundleName</key>
    <string>Retain</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Copy icon from Resources folder
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns dist/Retain.app/Contents/Resources/
elif [ -f "Retain.app/Contents/Resources/AppIcon.icns" ]; then
    cp Retain.app/Contents/Resources/AppIcon.icns dist/Retain.app/Contents/Resources/
else
    echo "Warning: AppIcon.icns not found in Resources/ or Retain.app/Contents/Resources/"
fi

# Touch to refresh icon cache
touch dist/Retain.app

echo "Build complete: dist/Retain.app"
echo ""
echo "To test fresh:"
echo "  rm -rf ~/Library/Application\\ Support/Retain && rm ~/Library/Preferences/com.empatika.Retain.plist && open dist/Retain.app"
