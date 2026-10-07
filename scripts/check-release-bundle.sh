#!/usr/bin/env bash
#
# Fails when any Mach-O in an app bundle holds anything but arm64: Redlamp runs on Apple
# Silicon only, so an Intel slice is size the download carries for nothing.
#
#   scripts/check-release-bundle.sh build/release/Redlamp.app

set -euo pipefail

APP="${1:?usage: check-release-bundle.sh <app>}"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }

checked=0
wrong=()
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q Mach-O || continue
    checked=$((checked + 1))
    archs="$(lipo -archs "$file")"
    [ "$archs" = arm64 ] || wrong+=("$archs: ${file#"$APP"/}")
done < <(find "$APP" -type f -print0)

if [ "${#wrong[@]}" -gt 0 ]; then
    echo "error: ${#wrong[@]} of $checked Mach-O files aren't arm64 only:" >&2
    printf '  %s\n' "${wrong[@]}" >&2
    exit 1
fi
echo "==> All $checked Mach-O files are arm64 only."
