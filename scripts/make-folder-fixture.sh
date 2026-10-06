#!/usr/bin/env bash
# Builds a large tree of photos for measuring the Folders panel and filmstrip: <folders> folders of
# <per-folder> photos each, every one an APFS clone of one sample (no extra disk space). Needs only
# macOS (no Python or Xcode), so a measurement kit can run it (scripts/perf-kit.sh).
#
#   scripts/make-folder-fixture.sh <destination> [folders=500] [per-folder=100] [sample]
#
# Then: --folders-perf <destination> (see apps/RedlampMac/Sources/DebugFoldersPerformance.swift).
set -euo pipefail

destination=${1:?usage: make-folder-fixture.sh <destination> [folders] [per-folder] [sample]}
folders=${2:-500}
per_folder=${3:-100}
sample=${4:-"$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures/raw/_DSC0009.ARW"}
extension=".${sample##*.}"

started=$SECONDS
made=0
fill() {
    local directory=$1 photo target
    mkdir -p "$directory"
    for ((photo = 1; photo <= per_folder; photo++)); do
        target="$directory/$(printf 'IMG_%05d' "$photo")$extension"
        [[ -e "$target" ]] && continue
        cp -c "$sample" "$target" 2>/dev/null \
            || { echo "clonefile failed for $target (is the destination on APFS, the sample's volume?)" >&2; exit 1; }
        made=$((made + 1))
    done
}

# The first folder photo by photo; every other one cloned whole from it, in one call each.
first="$destination/Shoot 001"
fill "$first"
for ((folder = 2; folder <= folders; folder++)); do
    directory="$destination/$(printf 'Shoot %03d' "$folder")"
    if [[ -d "$directory" ]]; then
        fill "$directory"
    else
        cp -cR "$first" "$directory"
        made=$((made + per_folder))
    fi
done
echo "$made clones in $((SECONDS - started)) s: $folders folders of $per_folder under $destination"
