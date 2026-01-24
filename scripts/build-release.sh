#!/bin/bash
set -e

# Build script for Retain release using Xcode
# Creates an unsigned .app bundle ready for distribution
#
# Usage: ./scripts/build-release.sh [version] [build-number]
# Example: ./scripts/build-release.sh 0.1.7-beta 4

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
BUILD_DIR="$PROJECT_DIR/.build/xcode-release"
APP_NAME="Retain"

# Parse arguments or use defaults
VERSION="${1:-0.1.7-beta}"
BUILD_NUMBER="${2:-4}"

echo "=== Building $APP_NAME $VERSION (build $BUILD_NUMBER) ==="

# Clean previous build
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

cd "$PROJECT_DIR"

# Update version in project.yml
echo "Updating version in project.yml..."
sed -i '' "s/MARKETING_VERSION:.*/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION:.*/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml

# Check for xcodegen
if ! command -v xcodegen &> /dev/null; then
    echo "Error: xcodegen not found. Install with: brew install xcodegen"
    exit 1
fi

# Regenerate Xcode project
echo "Regenerating Xcode project..."
xcodegen generate

# Build with xcodebuild
echo "Building with xcodebuild..."
xcodebuild -project Retain.xcodeproj \
    -scheme Retain \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build

# Copy app to dist
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH"
    exit 1
fi

echo "Copying app to dist..."
cp -R "$APP_PATH" "$DIST_DIR/"

# Verify the build
echo ""
echo "=== Verifying Build ==="

# Check App Intents metadata
if [ -d "$DIST_DIR/$APP_NAME.app/Contents/Resources/Metadata.appintents" ]; then
    echo "✓ App Intents metadata present"
else
    echo "✗ App Intents metadata missing"
fi

# Check Sparkle framework
if [ -d "$DIST_DIR/$APP_NAME.app/Contents/Frameworks/Sparkle.framework" ]; then
    echo "✓ Sparkle framework present"
else
    echo "✗ Sparkle framework missing"
fi

# Check App Icon
if [ -f "$DIST_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns" ]; then
    echo "✓ App icon present"
else
    echo "✗ App icon missing (checking for Resources folder...)"
    ls -la "$DIST_DIR/$APP_NAME.app/Contents/Resources/" 2>/dev/null || true
fi

# Check version in Info.plist
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DIST_DIR/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "unknown")
BUILT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$DIST_DIR/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "unknown")
echo "✓ Version: $BUILT_VERSION (build $BUILT_BUILD)"

# Create zip for distribution
echo ""
echo "Creating distribution zip..."
cd "$DIST_DIR"
zip -r "$APP_NAME-$VERSION.zip" "$APP_NAME.app"

echo ""
echo "=== Build Complete ==="
echo "App bundle: $DIST_DIR/$APP_NAME.app"
echo "Distribution: $DIST_DIR/$APP_NAME-$VERSION.zip"
echo ""
echo "Next steps:"
echo "  1. Test locally: open $DIST_DIR/$APP_NAME.app"
echo "  2. Sign and notarize: ./scripts/sign-and-notarize.sh $VERSION"
