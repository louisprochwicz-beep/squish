#!/usr/bin/env bash
# Squish — release script.
# Bumps version, builds, signs the update via Sparkle EdDSA,
# and prints the <item> entry to paste into appcast.xml.
#
# Usage: ./release.sh 1.1
set -euo pipefail

VERSION="${1:?usage: ./release.sh <version> (e.g. 1.1)}"
NOTES="${2:-Bug fixes and improvements.}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
DMG_SRC="$ROOT/build/Squish.dmg"

# 1. Bump version in Info.plist
echo "→ Bumping version to $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$ROOT/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$ROOT/Resources/Info.plist"

# 2. Build
echo "→ Building"
"$ROOT/build.sh"

# 3. Versioned DMG name (kept for clarity in the GitHub releases page).
# We also keep a stable Squish.dmg copy so the URL
# https://github.com/USER/REPO/releases/latest/download/Squish.dmg
# always points to the most recent build without changing.
DMG_VERSIONED="$ROOT/build/Squish-$VERSION.dmg"
DMG_STABLE="$ROOT/build/Squish.dmg"
cp "$DMG_SRC" "$DMG_VERSIONED"
mv "$DMG_SRC" "$DMG_STABLE"

# 4. Sign the update via Sparkle EdDSA (private key pulled from Keychain)
echo "→ Signing update"
# sign_update prints e.g.  sparkle:edSignature="..." length="..."
# We extract ONLY the edSignature attribute — embedding the full output would
# duplicate `length` in the <enclosure> tag (which we write ourselves below)
# and Sparkle's strict XML parser rejects appcasts with duplicate attributes
# with a generic "Update Error" popup. (v1.0 → v1.1 update broke on exactly
# this; do not regress.)
SIGN_OUTPUT_RAW=$("$ROOT/vendor/Sparkle/bin/sign_update" "$DMG_VERSIONED")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT_RAW" | sed -E 's/.*(sparkle:edSignature="[^"]+").*/\1/')
SIZE=$(stat -f%z "$DMG_VERSIONED")
PUB_DATE=$(LC_ALL=en_US.UTF-8 date -u +"%a, %d %b %Y %H:%M:%S +0000")

# 5. Read URL prefix from Info.plist (we keep https://YOUR_USER.github.io/squish placeholder
#    by default — replace after enabling GitHub Pages)
FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$ROOT/Resources/Info.plist")
# Derive a download URL on GitHub Releases — convention: same user/repo as feed page
# e.g. https://github.com/<user>/squish/releases/download/v<version>/Squish-<version>.dmg
USER_REPO=$(echo "$FEED_URL" | sed -E 's|https://([^.]+)\.github\.io/([^/]+)/.*|\1/\2|')
DOWNLOAD_URL="https://github.com/$USER_REPO/releases/download/v$VERSION/Squish-$VERSION.dmg"

# 6. Output the appcast.xml entry
ENTRY_FILE="$ROOT/build/appcast-entry-$VERSION.xml"
cat > "$ENTRY_FILE" <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <p>$NOTES</p>
            ]]></description>
            <enclosure
                url="$DOWNLOAD_URL"
                length="$SIZE"
                type="application/octet-stream"
                $ED_SIGNATURE />
        </item>
EOF

echo
echo "════════════════════════════════════════════════════════════════"
echo "  ✓ Release v$VERSION ready"
echo "════════════════════════════════════════════════════════════════"
echo "  DMG:    $DMG_VERSIONED"
echo "  Size:   $(du -h "$DMG_VERSIONED" | awk '{print $1}')"
echo "  Entry:  $ENTRY_FILE"
echo
echo "  Next steps:"
echo "    1. Create the GitHub release and upload BOTH DMGs:"
echo "       gh release create v$VERSION \\"
echo "           \"$DMG_VERSIONED\" \\"
echo "           \"$DMG_STABLE\" \\"
echo "           --title \"v$VERSION\" --notes \"$NOTES\""
echo "       (The versioned name is for clarity on the releases page,"
echo "        Squish.dmg is what the stable /latest/download URL serves.)"
echo "    2. Insert the contents of $ENTRY_FILE at the TOP of docs/appcast.xml"
echo "       (just below <language>en</language>)"
echo "    3. Commit and push → GitHub Pages serves the new appcast"
echo "    4. Users get the update notification within 24h (or instantly via Cmd-U)"
echo
