#!/usr/bin/env bash
# Squish — build .app + .dmg via swiftc + hdiutil (no Xcode required)
# Embeds Sparkle.framework for auto-updates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Squish"
BUNDLE_ID="com.callbruno.squish"
DEPLOYMENT_TARGET="14.0"

BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_STAGE="$BUILD_DIR/dmg"
DMG_OUT="$BUILD_DIR/$APP_NAME.dmg"

SPARKLE_DIR="$ROOT/vendor/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "✗ Sparkle.framework missing at $SPARKLE_FRAMEWORK"
    echo "  Re-download via: curl -L \$(curl -sL https://api.github.com/repos/sparkle-project/Sparkle/releases/latest | grep browser_download_url | grep '.tar.xz\"' | head -1 | sed 's/.*\"\\(https.*\\)\"/\\1/') -o vendor/Sparkle.tar.xz && tar -xf vendor/Sparkle.tar.xz -C vendor/Sparkle"
    exit 1
fi

echo "→ Cleaning build dir"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

echo "→ Copying Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "→ Copying bundle resources (icon, svgs, …)"
# Copy any file from Resources/ (except Info.plist and the .iconset folder)
# into the bundle's Contents/Resources/ — auto picks up new assets.
find "$ROOT/Resources" -maxdepth 1 -type f \
    -not -name "Info.plist" \
    -exec cp {} "$APP_DIR/Contents/Resources/" \;

# Embed cwebp helper binary — ImageIO doesn't encode WEBP, so we shell out
# to libwebp's official cwebp tool. Sits next to the main executable.
if [ -f "$ROOT/vendor/bin/cwebp" ]; then
    echo "→ Embedding cwebp helper"
    cp "$ROOT/vendor/bin/cwebp" "$APP_DIR/Contents/MacOS/cwebp"
    chmod +x "$APP_DIR/Contents/MacOS/cwebp"
fi

# Embed pngquant helper binary — for TinyPNG-style lossy PNG compression.
# Without it, PNG export falls back to ImageIO's lossless encoder.
if [ -f "$ROOT/vendor/bin/pngquant" ]; then
    echo "→ Embedding pngquant helper"
    cp "$ROOT/vendor/bin/pngquant" "$APP_DIR/Contents/MacOS/pngquant"
    chmod +x "$APP_DIR/Contents/MacOS/pngquant"
fi

echo "→ Embedding Sparkle.framework"
cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/"

ARCH_HOST="$(uname -m)"   # arm64 or x86_64
SDK_PATH="$(xcrun --show-sdk-path)"

echo "→ Compiling Swift sources (target: ${ARCH_HOST}-apple-macos${DEPLOYMENT_TARGET})"
SOURCES=( "$ROOT"/Sources/*.swift )

xcrun swiftc \
    -O \
    -target "${ARCH_HOST}-apple-macos${DEPLOYMENT_TARGET}" \
    -sdk "$SDK_PATH" \
    -swift-version 5 \
    -parse-as-library \
    -F "$SPARKLE_DIR" \
    -framework Sparkle \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework CoreImage \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -framework CoreGraphics \
    -framework Vision \
    -framework PDFKit \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    "${SOURCES[@]}"

echo "→ Generating PkgInfo"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "→ Ad-hoc signing the app (including Sparkle XPC services + cwebp)"
# Sign nested XPC services first, then the framework, then helpers, then the app
find "$APP_DIR/Contents/Frameworks/Sparkle.framework" -type f -name "*.xpc" -exec codesign --force --sign - --timestamp=none {} \; 2>/dev/null || true
find "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices" -maxdepth 1 -type d 2>/dev/null | while read -r xpc; do
    codesign --force --sign - --timestamp=none "$xpc" 2>/dev/null || true
done
codesign --force --deep --sign - --timestamp=none "$APP_DIR/Contents/Frameworks/Sparkle.framework"
# Sign cwebp helper binary
if [ -f "$APP_DIR/Contents/MacOS/cwebp" ]; then
    codesign --force --sign - --timestamp=none "$APP_DIR/Contents/MacOS/cwebp"
fi
# Sign pngquant helper binary
if [ -f "$APP_DIR/Contents/MacOS/pngquant" ]; then
    codesign --force --sign - --timestamp=none "$APP_DIR/Contents/MacOS/pngquant"
fi
codesign --force --deep --sign - --timestamp=none "$APP_DIR"
echo "    ✓ signed"

echo "→ Building DMG"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_DIR" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null

echo
echo "✓ Built: $APP_DIR"
echo "✓ DMG:   $DMG_OUT"
du -h "$DMG_OUT" | awk '{print "  size: "$1}'
