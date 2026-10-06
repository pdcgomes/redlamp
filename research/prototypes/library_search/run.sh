#!/usr/bin/env bash
# The measurements behind docs/research/notes/LIB-cling.md. Parts: 1 text that isn't ASCII, 2 a mapped
# column store, 3 fuzzy matching and typos, 4 a busy package under a watched root. No arguments runs all.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
here=research/prototypes/library_search
out=build/proto-out/library_search
mkdir -p "$out"

xcrun swiftc -O -swift-version 5 "$here/main.swift" "$here/text_and_columns.swift" "$here/completion.swift" \
    -o "$out/library-search"
xcrun swiftc -O -swift-version 5 "$here/busy_package.swift" -o "$out/busy-package"

parts=("$@")
[ ${#parts[@]} -eq 0 ] && parts=(1 2 3 4)
uptime | tee "$out/results.txt"
search=()
for part in "${parts[@]}"; do
    [ "$part" != 4 ] && search+=("$part")
done
[ ${#search[@]} -gt 0 ] && "$out/library-search" "${search[@]}" | tee -a "$out/results.txt"
if [[ " ${parts[*]} " == *" 4 "* ]]; then
    echo "== 4. A busy package under a watched root ==" | tee -a "$out/results.txt"
    "$out/busy-package" | tee -a "$out/results.txt"
fi
