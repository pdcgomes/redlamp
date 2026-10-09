#!/bin/bash
# Round 2: the Redlamp 0.2.7 release itself, driven from outside (drive356), on a photo from the
# reporter's camera, on the runner's disk and on an exFAT disk image as the reporter's photos are;
# then the copy of the dialog (repro356) with its photos on the exFAT image. The system log of
# the app and the open panel's service is kept for the whole run.
set -u
cd "$(dirname "$0")"
OUT="$PWD/out"
mkdir -p "$OUT" bundles apps
sw_vers | tee "$OUT/sw_vers.txt"
START=$(date "+%Y-%m-%d %H:%M:%S")

curl -sSL -o redlamp.zip https://github.com/pdcgomes/redlamp/releases/download/v0.2.7-prealpha/Redlamp-0.2.7-prealpha.zip
ditto -x -k redlamp.zip apps/
APP="$PWD/apps/Redlamp.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
echo "app: $BUNDLE_ID $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|flags" | tee "$OUT/codesign.txt"
defaults write "$BUNDLE_ID" welcome.shown -int 99

mkdir -p Photos/Edited
curl -sSL -o Photos/P1117458.RW2 "https://raw.pixls.us/getfile.php/7790/nice/Panasonic%20-%20DC-S5M2%20-%2014bit%20%283%3A2%29.RW2"
shasum -a 256 Photos/P1117458.RW2

hdiutil create -size 200m -fs ExFAT -volname RLPhotos -type UDIF -quiet exfat.dmg
hdiutil attach -quiet exfat.dmg
mkdir -p /Volumes/RLPhotos/Photos/Edited
cp Photos/P1117458.RW2 /Volumes/RLPhotos/Photos/
mount | grep RLPhotos

drive() { # <label> <photo> <open>
  local dir="$OUT/$1"
  mkdir -p "$dir"
  echo "::group::$1"
  perl -e 'alarm shift; exec @ARGV' 240 bin/drive356 --app "$APP" --photo "$2" --open "$3" --out "$dir" >"$dir/log.txt" 2>&1
  echo "exit $?" >>"$dir/log.txt"
  cat "$dir/log.txt" | cut -c1-600
  echo "::endgroup::"
  grep -h "SUMMARY\|FAIL" "$dir/log.txt" | sed "s/^/$1: /" >>"$OUT/summary.txt" || true
  pkill -9 -x Redlamp 2>/dev/null
  sleep 3
}

drive app-key "$PWD/Photos/P1117458.RW2" key
drive app-toolbar "$PWD/Photos/P1117458.RW2" toolbar
drive app-previous "$PWD/Photos/P1117458.RW2" previous
drive app-key-again "$PWD/Photos/P1117458.RW2" key

make_bundle() { # <name> <bundle id> <binary>
  local app="$PWD/bundles/$1.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$3" "$app/Contents/MacOS/repro356"
  cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>repro356</string>
<key>CFBundleName</key><string>Repro356</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
  codesign --force --sign - "$app" >/dev/null 2>&1
  echo "$app/Contents/MacOS/repro356"
}
dir="$OUT/copy-v027-exfat"
mkdir -p "$dir"
perl -e 'alarm shift; exec @ARGV' 200 "$(make_bundle exfat app.redlamp.repro356.exfat bin/repro356)" --variant v027 --open key --out "$dir" --photos /Volumes/RLPhotos/Photos >"$dir/log.txt" 2>&1
grep -h "SUMMARY" "$dir/log.txt" | sed "s/^/copy-v027-exfat: /" >>"$OUT/summary.txt"

drive app-key-exfat /Volumes/RLPhotos/Photos/P1117458.RW2 key

log show --start "$START" --info --debug --style compact \
  --predicate 'process == "Redlamp" OR process CONTAINS[c] "openAndSavePanel" OR process == "repro356"' \
  >"$OUT/system.log" 2>&1
wc -l "$OUT/system.log"
echo "===== summary"
cat "$OUT/summary.txt"
