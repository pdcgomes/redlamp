#!/bin/bash
# Runs the copy of the Export dialog in each variant, each in a fresh app bundle of its own (its
# own bundle identifier, so the open panel's service starts cold), and collects the logs and
# screenshots in out/.
set -u
cd "$(dirname "$0")"
OUT="$PWD/out"
mkdir -p "$OUT" bundles
sw_vers | tee "$OUT/sw_vers.txt"

make_bundle() { # <name> <bundle id> <binary>: prints the bundle's executable
  local app="$PWD/bundles/$1.app"
  rm -rf "$app"
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
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
  codesign --force --sign - "$app" >/dev/null 2>&1
  echo "$app/Contents/MacOS/repro356"
}

run() { # <label> <binary> <variant> <open> [more arguments]
  local label=$1 bin=$2 variant=$3 open=$4
  shift 4
  local dir="$OUT/$label"
  mkdir -p "$dir"
  echo "::group::$label"
  perl -e 'alarm shift; exec @ARGV' 200 "$bin" --variant "$variant" --open "$open" --out "$dir" "$@" >"$dir/log.txt" 2>&1
  echo "exit $?" >>"$dir/log.txt"
  grep -E "launched|trusted|present:|command|toolbar Export|setter|NSOpenPanel|runModal|sheet|panel visible|menu (began|ended)|probe|clicked|pressed|RESULT|SUMMARY|FAIL|WATCHDOG|refusing|mapping" "$dir/log.txt" | head -160
  echo "::endgroup::"
  grep -h "SUMMARY" "$dir/log.txt" >>"$OUT/summary.txt" || echo "$label: no summary" >>"$OUT/summary.txt"
  sleep 2
}

B=bin/repro356 # built on macOS 26.6 with Xcode 26.6 and the macOS 26 SDK, as Redlamp's releases are
run v027-key "$(make_bundle v027 app.redlamp.repro356.v027 $B)" v027 key
run v027-previous "$(make_bundle v027p app.redlamp.repro356.v027p $B)" v027 previous
run v027-toolbar "$(make_bundle v027t app.redlamp.repro356.v027t $B)" v027 toolbar
run v026-key "$(make_bundle v026 app.redlamp.repro356.v026 $B)" v026 key
run v026-previous "$(make_bundle v026p app.redlamp.repro356.v026p $B)" v026 previous
run sheetDeferred-key "$(make_bundle sheetDeferred app.redlamp.repro356.sheetdeferred $B)" sheetDeferred key
run button-key "$(make_bundle button app.redlamp.repro356.button $B)" button key
run noAppModal-key "$(make_bundle noAppModal app.redlamp.repro356.noappmodal $B)" noAppModal key
run warm-key "$(make_bundle warm app.redlamp.repro356.warm $B)" warm key
run v027-key-again "$(make_bundle v027 app.redlamp.repro356.v027 $B)" v027 key
run v027-key-original "$(make_bundle v027o app.redlamp.repro356.v027o $B)" v027 key --initial original

if xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos26.0 repro356.swift -o bin/repro356-sdk27 >"$OUT/build-sdk27.txt" 2>&1; then
  run v027-key-sdk27 "$(make_bundle v027s27 app.redlamp.repro356.v027s27 bin/repro356-sdk27)" v027 key
else
  echo "the macOS 27 SDK build failed" >>"$OUT/summary.txt"
fi

echo "===== summary"
cat "$OUT/summary.txt"
