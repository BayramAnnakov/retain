#!/bin/bash
set -e

# Build script for Retain release
# Creates an unsigned .app bundle ready for distribution

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Retain"
VERSION="0.1.0-beta"

echo "=== Building $APP_NAME $VERSION ==="

# Clean previous build
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Build release binary
echo "Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

# Create app bundle structure
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
echo "Creating app bundle..."
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Generate app icon (skip in CI - requires GUI context)
if [ -z "$CI" ]; then
    echo "Generating app icon..."
    chmod +x "$SCRIPT_DIR/generate-icon.swift"
    swift "$SCRIPT_DIR/generate-icon.swift" "$DIST_DIR"

    # Convert iconset to icns
    if [ -d "$DIST_DIR/AppIcon.iconset" ]; then
        iconutil -c icns "$DIST_DIR/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
        rm -rf "$DIST_DIR/AppIcon.iconset"
        echo "App icon created: AppIcon.icns"
    fi
else
    echo "Skipping icon generation in CI (requires GUI context)"
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.empatika.Retain</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Create zip for distribution
echo "Creating distribution zip..."
cd "$DIST_DIR"
zip -r "$APP_NAME-$VERSION.zip" "$APP_NAME.app"

echo ""
echo "=== Build Complete ==="
echo "App bundle: $APP_BUNDLE"
echo "Distribution: $DIST_DIR/$APP_NAME-$VERSION.zip"
echo ""
echo "To test locally:"
echo "  open $APP_BUNDLE"
echo ""
echo "For users to bypass Gatekeeper:"
echo "  xattr -cr $APP_BUNDLE"
