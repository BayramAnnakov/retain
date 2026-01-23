#!/bin/bash
set -e

# Build script for Retain release
# Creates an unsigned .app bundle ready for distribution

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Retain"
VERSION="0.1.4-beta"

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

# Copy Sparkle framework
echo "Copying Sparkle framework..."
SPARKLE_FRAMEWORK="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"

    # Add rpath to find the framework at runtime
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    echo "Sparkle framework copied and rpath set"
else
    echo "Warning: Sparkle framework not found at $SPARKLE_FRAMEWORK"
    echo "Run: swift package resolve"
fi

# Generate app icon (skip in CI - requires GUI context)
# GitHub Actions sets CI=true and GITHUB_ACTIONS=true
if [ "$CI" = "true" ] || [ "$GITHUB_ACTIONS" = "true" ]; then
    echo "Skipping icon generation in CI (requires GUI context)"
else
    echo "Generating app icon..."
    chmod +x "$SCRIPT_DIR/generate-icon.swift"
    swift "$SCRIPT_DIR/generate-icon.swift" "$DIST_DIR"

    # Convert iconset to icns
    if [ -d "$DIST_DIR/AppIcon.iconset" ]; then
        iconutil -c icns "$DIST_DIR/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
        rm -rf "$DIST_DIR/AppIcon.iconset"
        echo "App icon created: AppIcon.icns"
    fi
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
    <!-- Sparkle Auto-Update Configuration -->
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/BayramAnnakov/retain/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>0oUDQBQMD7S9b04m7u/UmG6ee9KX9IfgtVCbOsgMK+M=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAllowsAutomaticUpdates</key>
    <true/>
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
