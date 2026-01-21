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

# Recreate DMG with notarized app
echo ""
echo "=== Creating notarized DMG ==="
rm -f "$DIST_DIR/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DIST_DIR/$APP_NAME.app" \
    -ov -format UDZO \
    "$DIST_DIR/$APP_NAME-$VERSION.dmg"

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
