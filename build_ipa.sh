#!/bin/bash
# ============================================
# RifatCam Pro - iOS Build Script
# Run this on a Mac with Xcode installed
# ============================================

set -e

echo "========================================="
echo "  RifatCam Pro - iOS IPA Builder"
echo "========================================="

# Check Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: Xcode not found!"
    echo "Install from: https://developer.apple.com/xcode/"
    exit 1
fi

XCODE_VER=$(xcodebuild -version | head -1)
echo "Using: $XCODE_VER"

# Check project
PROJECT="RifatCamPro/RifatCamPro.xcodeproj"
SCHEME="RifatCamPro"

if [ ! -d "$PROJECT" ]; then
    echo "ERROR: $PROJECT not found!"
    echo "Run this script from the project root:"
    echo "  cd RifatCam_Pro"
    echo "  chmod +x build_ipa.sh"
    echo "  ./build_ipa.sh"
    exit 1
fi

echo ""
echo "[1/4] Cleaning build..."
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    clean

echo ""
echo "[2/4] Building archive..."
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath build/RifatCamPro.xcarchive \
    -destination "generic/platform=iOS" \
    archive

echo ""
echo "[3/4] Exporting IPA..."

# Create export options
cat > build/ExportOptions.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string></string>
    <key>uploadBitcode</key>
    <false/>
    <key>compileBitcode</key>
    <false/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath build/RifatCamPro.xcarchive \
    -exportOptionsPlist build/ExportOptions.plist \
    -exportPath build/ipa

echo ""
echo "[4/4] Done!"
echo ""
echo "========================================="
echo "  IPA File Location:"
echo "  build/ipa/RifatCamPro.ipa"
echo "========================================="
echo ""
echo "Install on iPhone:"
echo "  1. Connect iPhone via USB"
echo "  2. Open Xcode > Window > Devices"
echo "  3. Drag .ipa onto your device"
echo ""
echo "OR use AltStore:"
echo "  1. Install AltStore on iPhone"
echo "  2. Open .ipa in AltStore"
echo ""
