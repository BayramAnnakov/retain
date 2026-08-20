#!/usr/bin/env bash
set -e

REPO="tolmachevmaxim/retain"
echo "🔍 Fetching latest Retain release from https://github.com/$REPO..."

# Get latest release download URL via GitHub API
DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep "browser_download_url.*\.zip" | cut -d : -f 2,3 | tr -d ' "')

if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/v0.1.11-antigravity/Retain-v0.1.11-antigravity-arm64.zip"
fi

TMP_ZIP="/tmp/Retain-latest.zip"
echo "⬇️ Downloading Retain ($DOWNLOAD_URL)..."
curl -fL "$DOWNLOAD_URL" -o "$TMP_ZIP"

echo "📦 Installing Retain to /Applications/..."
pkill -f "Retain.app" 2>/dev/null || true
rm -rf /Applications/Retain.app
unzip -qo "$TMP_ZIP" -d /Applications/
rm -f "$TMP_ZIP"

xattr -cr /Applications/Retain.app 2>/dev/null || true

echo "✅ Retain successfully installed to /Applications/Retain.app!"
echo "🚀 Launching Retain..."
open /Applications/Retain.app
