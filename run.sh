#!/bin/bash
# Round 4: the reporter's setup (a previous destination, Edited, on an exFAT volume with the
# photo) in full screen, in Stage Manager, and with a 2x main display and the editor on a 1x one.
# The 0.2.7 release (drive356) and the copy of the dialog (repro356).
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
defaults write "$BUNDLE_ID" welcome.shown -int 99

hdiutil create -size 300m -fs ExFAT -volname RLPhotos -type UDIF -quiet exfat.dmg
hdiutil attach -quiet exfat.dmg
PHOTOS=/Volumes/RLPhotos/Photos
mkdir -p "$PHOTOS/Edited"
curl -sSL -o "$PHOTOS/P1117458.RW2" "https://raw.pixls.us/getfile.php/7790/nice/Panasonic%20-%20DC-S5M2%20-%2014bit%20%283%3A2%29.RW2"
shasum -a 256 "$PHOTOS/P1117458.RW2"
for i in 1 2 3; do sips -s format jpeg -z 400 600 /System/Library/Desktop\ Pictures/*.heic --out "$PHOTOS/Edited/P111745$i-redlamp.jpg" >/dev/null 2>&1 || true; done
ls -la "$PHOTOS" "$PHOTOS/Edited"
previous=$(printf '{"destinationFolder":"file://%s/Edited/"}' "$PHOTOS" | xxd -p | tr -d '\n')
defaults write "$BUNDLE_ID" exportPrevious -data "$previous"
defaults read "$BUNDLE_ID" exportPrevious | head -c 300; echo

drive() { # <label> <screen> [more arguments]
  local dir="$OUT/$1" screen=$2
  shift 2
  mkdir -p "$dir"
  echo "::group::$dir"
  perl -e 'alarm shift; exec @ARGV' 240 bin/drive356 --app "$APP" --photo "$PHOTOS/P1117458.RW2" --open key --screen "$screen" --out "$dir" "$@" >"$dir/log.txt" 2>&1
  echo "exit $?" >>"$dir/log.txt"
  cut -c1-600 "$dir/log.txt"
  echo "::endgroup::"
  grep -h "SUMMARY\|FAIL" "$dir/log.txt" | sed "s/^/$1: /" >>"$OUT/summary.txt" || true
  pkill -9 -x Redlamp 2>/dev/null
  sleep 3
}

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

copy() { # <label> <variant> <screen> [more arguments]
  local dir="$OUT/$1" label=$1 variant=$2 screen=$3
  shift 3
  mkdir -p "$dir"
  echo "::group::$label"
  perl -e 'alarm shift; exec @ARGV' 200 "$(make_bundle "$label" "app.redlamp.repro356.$label" bin/repro356)" --variant "$variant" --open key --screen "$screen" --photos "$PHOTOS" --out "$dir" "$@" >"$dir/log.txt" 2>&1
  grep -E "launched|screens|editor goes|full screen|setter|NSOpenPanel|runModal|panel visible|RESULT|SUMMARY|FAIL|refusing|mapping" "$dir/log.txt" | cut -c1-400 | head -60
  echo "::endgroup::"
  grep -h "SUMMARY\|FAIL" "$dir/log.txt" | sed "s/^/$1: /" >>"$OUT/summary.txt" || true
  sleep 2
}

drive app-fullscreen main --fullscreen
copy copy-v027-fullscreen v027 main --fullscreen

defaults write com.apple.WindowManager GloballyEnabled -bool true
killall WindowManager 2>/dev/null
sleep 4
echo "Stage Manager: $(defaults read com.apple.WindowManager GloballyEnabled)"
drive app-stagemanager main
copy copy-v027-stagemanager v027 main
defaults write com.apple.WindowManager GloballyEnabled -bool false
killall WindowManager 2>/dev/null
sleep 4

bin/vdisplay 1512x982@2 3440x1440@1 >"$OUT/vdisplay.txt" 2>&1 &
VD=$!
sleep 8
cat "$OUT/vdisplay.txt"
system_profiler SPDisplaysDataType | sed -n '1,60p' >"$OUT/displays.txt"
drive app-external external
drive app-external-fullscreen external --fullscreen
copy copy-v027-external v027 external

kill $VD
log show --start "$START" --info --style compact \
  --predicate 'process == "Redlamp" OR process CONTAINS[c] "openAndSavePanel" OR process == "repro356"' \
  >"$OUT/system.log" 2>&1
wc -l "$OUT/system.log"
echo "===== summary"
cat "$OUT/summary.txt"
