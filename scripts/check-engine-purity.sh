#!/usr/bin/env bash
#
# Engine purity CI gate.
#
# Redlamp's engine layers are platform-neutral and UI-free: they must build for
# macOS, iPadOS and iOS and must never know about windows, views or UI state. This
# script fails on any UI framework import in an engine package, and on any UI package
# that reaches past RedlampEngineAPI into engine internals.
#
# If you hit this check, move the code to the right side of the boundary or expose
# what you need through RedlampEngineAPI. Never silence the check — the rule is
# architectural.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENGINE_PACKAGES=(
    RedlampEngineAPI
    RedlampKernels
    RedlampColor
    RedlampServices
    RedlampDocument
    RedlampRecipes
    RedlampMasking
    RedlampEngine
    RedlampGenerative
)
UI_PACKAGES=(
    RedlampCanvas
    RedlampDesign
    RedlampUI
    RedlampAutomation
)

FORBIDDEN_IN_ENGINE='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(AppKit|UIKit|SwiftUI|Cocoa|RedlampUI|RedlampCanvas|RedlampDesign)\b'
FORBIDDEN_IN_UI='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(RedlampEngine|RedlampKernels|RedlampColor|RedlampServices|RedlampMasking|RedlampGenerative)\b'

failed=0

for package in "${ENGINE_PACKAGES[@]}"; do
    dir="$ROOT/packages/$package/Sources"
    [[ -d "$dir" ]] || continue
    if matches=$(grep -RInE --include='*.swift' "$FORBIDDEN_IN_ENGINE" "$dir"); then
        echo "UI import found in engine package $package:"
        echo "$matches"
        echo
        failed=1
    fi
done

for package in "${UI_PACKAGES[@]}"; do
    dir="$ROOT/packages/$package/Sources"
    [[ -d "$dir" ]] || continue
    if matches=$(grep -RInE --include='*.swift' "$FORBIDDEN_IN_UI" "$dir"); then
        echo "Engine-internal import found in UI package $package (use RedlampEngineAPI):"
        echo "$matches"
        echo
        failed=1
    fi
done

# The engine and the UI read files through an ImageDecoding (the Mac app's sandboxed decode
# service), never with the decoders or thumbnail readers themselves, so a damaged file can't take
# the app down. Only RedlampServices' InProcessDecoder calls them, for the CLI and tests, and
# these known exceptions (file, call, reason), which DATA-17 tracks moving into the service:
DIRECT_READ='\b(ImageDecoder|RawDecoder|BitmapDecoder|Thumbnails)\.'
ALLOWED_READS=(
    "RedlampEngine/Sources/RedlampEngine.swift|Thumbnails.thumbnail(|filmstrip thumbnails; the service's lookup missed the first-visit budget"
    "RedlampEngine/Sources/RedlampEngine+Thumbnails.swift|Thumbnails.thumbnail(|filmstrip thumbnails, as above"
    "RedlampEngine/Sources/RedlampEngine+CameraBench.swift|ImageDecoder.identify(|Camera Bench: identifying each file in the chosen folder"
    "RedlampEngine/Sources/RedlampEngine+CameraBench.swift|Thumbnails.cameraPreview(|Camera Bench: the camera's own JPEG"
    "RedlampEngine/Sources/RedlampEngine+CameraBench.swift|ImageDecoder.rawDecoderVersion|LibRaw's version string, which reads no file"
)
allowed_read() {
    local match=$1 entry path call
    for entry in "${ALLOWED_READS[@]}"; do
        IFS='|' read -r path call _ <<<"$entry"
        [[ "${match%%:*}" == */packages/$path && "$match" == *"$call"* ]] && return 0
    done
    return 1
}
for package in RedlampEngine RedlampUI; do
    dir="$ROOT/packages/$package/Sources"
    [[ -d "$dir" ]] || continue
    matches=""
    while IFS= read -r match; do
        allowed_read "$match" || matches+="$match"$'\n'
    done < <(grep -RInE --include='*.swift' "$DIRECT_READ" "$dir" || true)
    if [[ -n "$matches" ]]; then
        echo "Direct file read in $package (read through the engine's ImageDecoding):"
        printf '%s' "$matches"
        echo
        failed=1
    fi
done

# Nor do they make their own InProcessDecoder: the only one is the default of RedlampEngine's
# initialiser, for the CLI and tests, which the Mac app replaces with the decode service.
ENGINE_DEFAULT='/RedlampEngine/Sources/RedlampEngine\.swift:[0-9]+:[[:space:]]*decoder: any ImageDecoding = InProcessDecoder\(\),$'
for package in RedlampEngine RedlampUI; do
    dir="$ROOT/packages/$package/Sources"
    [[ -d "$dir" ]] || continue
    if matches=$(grep -RInE --include='*.swift' '\bInProcessDecoder\(' "$dir" | grep -vE "$ENGINE_DEFAULT"); then
        echo "InProcessDecoder made in $package (use the engine's decoder):"
        echo "$matches"
        echo
        failed=1
    fi
done

if [[ $failed -ne 0 ]]; then
    exit 1
fi
echo "check-engine-purity: OK"
