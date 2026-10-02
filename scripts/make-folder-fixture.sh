#!/usr/bin/env bash
# Builds a large tree of photos for measuring the Folders panel and filmstrip: <folders> folders of
# <per-folder> photos each, every one an APFS clone of one sample (no extra disk space).
#
#   scripts/make-folder-fixture.sh <destination> [folders=500] [per-folder=100] [sample]
#
# Then: --folders-perf <destination> (see apps/RedlampMac/Sources/DebugFoldersPerformance.swift).
set -euo pipefail

destination=${1:?usage: make-folder-fixture.sh <destination> [folders] [per-folder] [sample]}
folders=${2:-500}
per_folder=${3:-100}
sample=${4:-"$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures/raw/_DSC0009.ARW"}

python3 - "$destination" "$folders" "$per_folder" "$sample" <<'PY'
import ctypes, os, sys, time

destination, folders, per_folder, sample = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
libc = ctypes.CDLL("libc.dylib", use_errno=True)
libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
extension = os.path.splitext(sample)[1]
start = time.time()
made = 0
for folder in range(1, folders + 1):
    directory = os.path.join(destination, f"Shoot {folder:03d}")
    os.makedirs(directory, exist_ok=True)
    for photo in range(1, per_folder + 1):
        target = os.path.join(directory, f"IMG_{photo:05d}{extension}")
        if os.path.exists(target):
            continue
        if libc.clonefile(sample.encode(), target.encode(), 0) != 0:
            raise OSError(ctypes.get_errno(), f"clonefile failed for {target} (is the destination on APFS?)")
        made += 1
print(f"{made} clones in {time.time() - start:.1f} s: {folders} folders of {per_folder} under {destination}")
PY
