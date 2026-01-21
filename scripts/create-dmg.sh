#!/bin/bash
set -e

# Create DMG for Retain distribution
# Requires: build-release.sh to have run first, or pass --build flag
#
# Usage:
#   ./create-dmg.sh                    # Create unsigned DMG
#   ./create-dmg.sh --build            # Build first, then create unsigned DMG
#   ./create-dmg.sh --notarize         # Build, sign, notarize, create DMG
#   ./create-dmg.sh 0.2.0 --notarize   # Specify version

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Retain"
VERSION="0.1.0-beta"
DO_BUILD=false
DO_NOTARIZE=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --build)
            DO_BUILD=true
            ;;
        --notarize)
            DO_BUILD=true
            DO_NOTARIZE=true
            ;;
        *)
            # Assume it's a version number
            if [[ "$arg" =~ ^[0-9] ]]; then
                VERSION="$arg"
            fi
            ;;
    esac
done

# Build if requested
if [ "$DO_BUILD" = true ]; then
    echo "=== Building $APP_NAME first ==="
    "$SCRIPT_DIR/build-release.sh"
fi

# Sign and notarize if requested
if [ "$DO_NOTARIZE" = true ]; then
    "$SCRIPT_DIR/sign-and-notarize.sh" "$VERSION"
    echo ""
    echo "=== Notarized release complete ==="
    exit 0
fi

DMG_NAME="$APP_NAME-$VERSION"

# Verify app bundle exists
if [ ! -d "$DIST_DIR/$APP_NAME.app" ]; then
    echo "Error: $DIST_DIR/$APP_NAME.app not found"
    echo "Run ./scripts/build-release.sh first, or pass --build flag"
    exit 1
fi

echo "=== Creating DMG for $APP_NAME $VERSION ==="

# Remove existing DMG if present
rm -f "$DIST_DIR/$DMG_NAME.dmg"

# Create DMG
if command -v create-dmg &> /dev/null; then
    echo "Using create-dmg for styled DMG..."

    # Check if icon exists
    ICON_PATH="$DIST_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"
    ICON_ARGS=""
    if [ -f "$ICON_PATH" ]; then
        ICON_ARGS="--volicon $ICON_PATH"
    fi

    create-dmg \
        --volname "$APP_NAME" \
        $ICON_ARGS \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 185 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "$DIST_DIR/$DMG_NAME.dmg" \
        "$DIST_DIR/$APP_NAME.app"
else
    echo "create-dmg not found, using hdiutil..."
    echo "For styled DMG, install: brew install create-dmg"

    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DIST_DIR/$APP_NAME.app" \
        -ov -format UDZO \
        "$DIST_DIR/$DMG_NAME.dmg"
fi

# Verify DMG was created
if [ -f "$DIST_DIR/$DMG_NAME.dmg" ]; then
    DMG_SIZE=$(du -h "$DIST_DIR/$DMG_NAME.dmg" | cut -f1)
    echo ""
    echo "=== DMG Created Successfully ==="
    echo "File: $DIST_DIR/$DMG_NAME.dmg"
    echo "Size: $DMG_SIZE"
    echo ""
    echo "To test:"
    echo "  open $DIST_DIR/$DMG_NAME.dmg"
else
    echo "Error: Failed to create DMG"
    exit 1
fi
