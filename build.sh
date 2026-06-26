#!/bin/sh

VERSION=$(./get-version.sh) || exit 1

echo "Using version: $VERSION"

if [ -z "$GITHUB_WORKSPACE" ]; then
    GITHUB_WORKSPACE="$HOME"
fi

THEOS="$GITHUB_WORKSPACE/theos-roothide"
if [ ! -d "$THEOS" ]; then
    THEOS="$GITHUB_WORKSPACE/theos"
fi

xcodebuild clean build archive \
-scheme OverlayKit \
-project OverlayKit.xcodeproj \
-configuration Release \
-sdk iphoneos \
-destination 'generic/platform=iOS' \
-archivePath OverlayKit \
CODE_SIGNING_ALLOWED=NO \
IPHONEOS_DEPLOYMENT_TARGET=14.0 \
THEOS="$THEOS" | xcpretty

chmod 0644 Resources/Info.plist
cp supports/entitlements.plist OverlayKit.xcarchive/Products
cd OverlayKit.xcarchive/Products/Applications || exit
codesign --remove-signature TrollSpeed.app
cd - || exit
cd OverlayKit.xcarchive/Products || exit
mv Applications Payload
ldid -Sentitlements.plist Payload/TrollSpeed.app
chmod 0644 Payload/TrollSpeed.app/Info.plist
zip -qr OverlayKit.tipa Payload
cd - || exit
mkdir -p packages
mv OverlayKit.xcarchive/Products/OverlayKit.tipa packages/OverlayKit_$VERSION.tipa
