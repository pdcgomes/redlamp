#!/usr/bin/env bash
#
# Prints a one-item Sparkle appcast for a signed and zipped Redlamp.app:
#
#   scripts/appcast.sh <Redlamp.app> <zip> <zip URL> <notes.md>
#
# The versions and minimum macOS come from the app's Info.plist, and Sparkle's update window
# shows the notes as Markdown. sign_update signs the zip with the release key
# (`generate_keys --account redlamp`), so the keychain may ask to let it use the key.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN="$ROOT/Tuist/.build/artifacts/sparkle/Sparkle/bin"

if [ "$#" -ne 4 ]; then
    echo "usage: scripts/appcast.sh <Redlamp.app> <zip> <zip URL> <notes.md>" >&2
    exit 1
fi
APP="$1"
ZIP="$2"
URL="$3"
NOTES="$4"

info() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"
}

VERSION="$(info CFBundleShortVersionString)"
BUILD="$(info CFBundleVersion)"
# Sparkle compares three-part versions.
MINIMUM_OS="$(info LSMinimumSystemVersion)"
[[ "$MINIMUM_OS" == *.*.* ]] || MINIMUM_OS="$MINIMUM_OS.0"
# sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account redlamp "$ZIP")"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Redlamp</title>
        <item>
            <title>Redlamp $VERSION</title>
            <pubDate>$(LC_ALL=C date -R)</pubDate>
            <link>https://redlamp.app</link>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINIMUM_OS</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>https://github.com/pdcgomes/redlamp/releases</sparkle:fullReleaseNotesLink>
            <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES")
]]></description>
            <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
        </item>
    </channel>
</rss>
EOF
