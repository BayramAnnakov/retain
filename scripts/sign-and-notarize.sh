#!/bin/bash
set -e

# Sign and notarize Retain for distribution
# Requires: Developer ID certificate and app-specific password

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Retain"
VERSION="${1:-0.1.0-beta}"

# Signing identity and notarization credentials
DEVELOPER_ID="Developer ID Application: Bayram Annakov (AM7RDT263T)"
APPLE_ID="bayram.annakov@empatika.com"
TEAM_ID="AM7RDT263T"

# Check for app bundle
if [ ! -d "$DIST_DIR/$APP_NAME.app" ]; then
    echo "Error: $DIST_DIR/$APP_NAME.app not found"
    echo "Run ./scripts/build-release.sh first"
    exit 1
fi

echo "=== Signing and Notarizing $APP_NAME $VERSION ==="

# Step 1: Sign the app
echo ""
echo "[1/4] Signing app bundle..."
codesign --deep --force --verify --verbose \
    --sign "$DEVELOPER_ID" \
    --options runtime \
    --timestamp \
    "$DIST_DIR/$APP_NAME.app"

# Verify signature
codesign -dv --verbose=2 "$DIST_DIR/$APP_NAME.app" 2>&1 | grep -E "^(Authority|Identifier|Timestamp)"

# Step 2: Create zip for notarization
echo ""
echo "[2/4] Creating zip for notarization..."
rm -f "$DIST_DIR/$APP_NAME-notarize.zip"
ditto -c -k --keepParent "$DIST_DIR/$APP_NAME.app" "$DIST_DIR/$APP_NAME-notarize.zip"

# Step 3: Submit for notarization
echo ""
echo "[3/4] Submitting for notarization (this may take a few minutes)..."

# Try keychain profile first, fall back to prompting
if xcrun notarytool submit "$DIST_DIR/$APP_NAME-notarize.zip" \
    --keychain-profile "AC_PASSWORD" \
    --wait 2>/dev/null; then
    echo "Notarization complete (using keychain profile)"
else
    echo "Keychain profile not found. Using credentials directly..."
    echo "You may need to enter your app-specific password."
    xcrun notarytool submit "$DIST_DIR/$APP_NAME-notarize.zip" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --wait
fi

# Step 4: Staple the ticket
echo ""
echo "[4/4] Stapling notarization ticket..."
xcrun stapler staple "$DIST_DIR/$APP_NAME.app"

# Verify Gatekeeper
echo ""
echo "=== Verifying Gatekeeper ==="
spctl -a -vv "$DIST_DIR/$APP_NAME.app" 2>&1

# Recreate DMG with notarized app (with Applications link)
echo ""
echo "=== Creating notarized DMG ==="
rm -f "$DIST_DIR/$APP_NAME-$VERSION.dmg"

# Create staging directory with app and Applications symlink
STAGING_DIR="$DIST_DIR/dmg_staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$DIST_DIR/$APP_NAME.app" "$STAGING_DIR/"
ln -sf /Applications "$STAGING_DIR/Applications"

# Function to create DMG using sparse image (workaround for permission issues)
create_dmg_sparse() {
    local output_dmg="$1"
    local staging="$2"
    local volname="$3"

    local sparse_img="/tmp/retain_sparse_$$.sparseimage"
    local mount_point="/tmp/retain_mount_$$"

    rm -f "$sparse_img" 2>/dev/null
    rm -rf "$mount_point" 2>/dev/null

    hdiutil create -size 100m -fs HFS+ -volname "$volname" -type SPARSE "$sparse_img" && \
    hdiutil attach "$sparse_img" -mountpoint "$mount_point" && \
    cp -R "$staging"/* "$mount_point/" && \
    hdiutil detach "$mount_point" && \
    hdiutil convert "$sparse_img" -format UDZO -o "$output_dmg" -ov && \
    rm -f "$sparse_img"
}

DMG_CREATED=false

if command -v create-dmg &> /dev/null; then
    ICON_PATH="$DIST_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"
    ICON_ARGS=""
    if [ -f "$ICON_PATH" ]; then
        ICON_ARGS="--volicon $ICON_PATH"
    fi

    # Try create-dmg first (produces nicer DMG with window layout)
    if create-dmg \
        --volname "$APP_NAME" \
        $ICON_ARGS \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 185 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "$DIST_DIR/$APP_NAME-$VERSION.dmg" \
        "$STAGING_DIR" 2>/dev/null; then
        echo "DMG created with create-dmg"
        DMG_CREATED=true
    fi
fi

# Fallback to hdiutil direct method
if [ "$DMG_CREATED" = false ]; then
    echo "Trying hdiutil direct method..."
    if hdiutil create -volname "$APP_NAME" \
        -srcfolder "$STAGING_DIR" \
        -ov -format UDZO \
        "$DIST_DIR/$APP_NAME-$VERSION.dmg" 2>/dev/null; then
        echo "DMG created with hdiutil"
        DMG_CREATED=true
    fi
fi

# Final fallback to sparse image method (works around permission issues)
if [ "$DMG_CREATED" = false ]; then
    echo "Using sparse image method (permission workaround)..."
    if create_dmg_sparse "$DIST_DIR/$APP_NAME-$VERSION.dmg" "$STAGING_DIR" "$APP_NAME"; then
        echo "DMG created with sparse image method"
        DMG_CREATED=true
    else
        echo "ERROR: All DMG creation methods failed"
        exit 1
    fi
fi

# Cleanup staging
rm -rf "$STAGING_DIR"

# Sign and notarize the DMG itself (required for Sparkle auto-updates)
echo ""
echo "=== Signing and notarizing DMG ==="
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
codesign --force --sign "Developer ID Application: Bayram Annakov (AM7RDT263T)" "$DMG_PATH"
echo "DMG signed, submitting for notarization..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple "$DMG_PATH"
echo "DMG notarized and stapled"

# Recreate zip with notarized app
echo ""
echo "=== Creating notarized zip ==="
rm -f "$DIST_DIR/$APP_NAME-$VERSION.zip"
cd "$DIST_DIR"
zip -r "$APP_NAME-$VERSION.zip" "$APP_NAME.app"

# Clean up
rm -f "$DIST_DIR/$APP_NAME-notarize.zip"

echo ""
echo "=== Sign and Notarize Complete ==="
echo "DMG: $DIST_DIR/$APP_NAME-$VERSION.dmg"
echo "ZIP: $DIST_DIR/$APP_NAME-$VERSION.zip"
echo ""
echo "To test: open $DIST_DIR/$APP_NAME-$VERSION.dmg"
