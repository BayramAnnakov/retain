#!/bin/bash
set -e

# Generate Sparkle appcast.xml for Retain updates
# This script creates/updates the appcast file for auto-updates
#
# Usage: ./scripts/generate-appcast.sh <version> [release-notes]
# Example: ./scripts/generate-appcast.sh 0.1.3-beta "Bug fixes and improvements"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Retain"
VERSION="${1:-}"
RELEASE_NOTES="${2:-Bug fixes and improvements}"

# GitHub repo info (update if repo changes)
GITHUB_OWNER="BayramAnnakov"
GITHUB_REPO="retain"
DOWNLOAD_BASE="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [release-notes]"
    echo "Example: $0 0.1.3-beta \"Bug fixes and improvements\""
    exit 1
fi

# Check for DMG
DMG_FILE="$DIST_DIR/$APP_NAME-$VERSION.dmg"
if [ ! -f "$DMG_FILE" ]; then
    echo "Error: DMG not found: $DMG_FILE"
    echo "Run ./scripts/sign-and-notarize.sh $VERSION first"
    exit 1
fi

# Find Sparkle sign_update tool
SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -f "$SIGN_UPDATE" ]; then
    echo "Error: Sparkle sign_update tool not found"
    echo "Run: swift package resolve"
    exit 1
fi

echo "=== Generating Appcast for $APP_NAME $VERSION ==="

# Get file size
FILE_SIZE=$(stat -f%z "$DMG_FILE")

# Get current date in RFC 822 format
PUB_DATE=$(date -R)

# Generate EdDSA signature
echo "Signing DMG with EdDSA..."
SIGNATURE=$("$SIGN_UPDATE" "$DMG_FILE" 2>/dev/null | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')

if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to generate signature"
    echo "Make sure you have generated keys with: .build/artifacts/sparkle/Sparkle/bin/generate_keys"
    exit 1
fi

echo "Signature: ${SIGNATURE:0:20}..."

# Download URL
DOWNLOAD_URL="$DOWNLOAD_BASE/v$VERSION/$APP_NAME-$VERSION.dmg"

# Generate appcast.xml
APPCAST_FILE="$PROJECT_DIR/appcast.xml"

cat > "$APPCAST_FILE" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>$APP_NAME Updates</title>
        <link>https://github.com/$GITHUB_OWNER/$GITHUB_REPO</link>
        <description>Updates for $APP_NAME</description>
        <language>en</language>
        <item>
            <title>Version $VERSION</title>
            <description><![CDATA[
                <h2>What's New in $VERSION</h2>
                <p>$RELEASE_NOTES</p>
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="$DOWNLOAD_URL"
                length="$FILE_SIZE"
                type="application/octet-stream"
                sparkle:edSignature="$SIGNATURE"
            />
        </item>
    </channel>
</rss>
EOF

echo ""
echo "=== Appcast Generated ==="
echo "File: $APPCAST_FILE"
echo "Version: $VERSION"
echo "Download URL: $DOWNLOAD_URL"
echo "File Size: $FILE_SIZE bytes"
echo ""
echo "Next steps:"
echo "1. Commit appcast.xml to main branch"
echo "2. Push to GitHub (raw.githubusercontent.com will serve it)"
echo ""
echo "Commands:"
echo "  git add appcast.xml"
echo "  git commit -m \"Update appcast for v$VERSION\""
echo "  git push origin main"
