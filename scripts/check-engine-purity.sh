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
# service), not with the decoders or thumbnail readers themselves. Only RedlampServices'
# InProcessDecoder calls them, for the CLI and tests, and these known exceptions (file, call,
# reason), each allowing one call. DATA-17 lists them with the rest of the parsing the app
# still does itself.
DIRECT_READ='\b(ImageDecoder|RawDecoder|BitmapDecoder|Thumbnails)\.'
ALLOWED_READS=(
    "RedlampEngine/Sources/RedlampEngine.swift|Thumbnails.thumbnail(|filmstrip thumbnails; the service's lookup missed the first-visit budget"
    "RedlampEngine/Sources/RedlampEngine+Thumbnails.swift|Thumbnails.thumbnail(|filmstrip thumbnails, as above"
    "RedlampEngine/Sources/RedlampEngine+CameraBench.swift|ImageDecoder.identify(|Camera Bench: identifying each file in the chosen folder"
    "RedlampEngine/Sources/RedlampEngine+CameraBench.swift|Thumbnails.cameraPreview(|Camera Bench: the camera's own JPEG"
    "RedlampEngine/Sources/RedlampEngine+CameraBench.swift|ImageDecoder.rawDecoderVersion|LibRaw's version string, which reads no file"
)
allowed_uses=()
allowed_read() {
    local match=$1 i path call
    for i in "${!ALLOWED_READS[@]}"; do
        IFS='|' read -r path call _ <<<"${ALLOWED_READS[$i]}"
        if [[ "${match%%:*}" == */packages/$path && "$match" == *"$call"* && -z "${allowed_uses[$i]:-}" ]]; then
            allowed_uses[$i]=1
            return 0
        fi
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

# Nothing throws while an encoder is open: one released without endEncoding() aborts under
# Metal's validation layer, so a buffer or texture that fails to allocate would crash a Debug
# build. Open the encoder with withComputeEncoder, which ends it on every exit, or make
# everything that can fail first. The guard that makes the encoder may throw.
OPEN_ENCODER_THROWS='
/^[[:space:]]*\/\// { next }
/^[[:space:]]*((public|private|fileprivate|internal|static|override|mutating)[[:space:]]+)*func[[:space:]]/ { open = 0 }
open && /endEncoding\(\)/ { open = 0 }
open && skipping { if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) skipping = 0; next }
open && /^[[:space:]]*else[[:space:]]*\{[[:space:]]*throw[^}]*}[[:space:]]*$/ { next }
open && /^[[:space:]]*else[[:space:]]*\{[[:space:]]*$/ { skipping = 1; next }
open && /(^|[^A-Za-z_])(try([^?A-Za-z_]|$)|throw([^A-Za-z_]|$))/ { print FILENAME ":" FNR ": " $0 }
/make(Compute|Blit|Render)CommandEncoder\(/ && !/endEncoding\(\)/ { open = 1; skipping = 0 }
'
for package in "${ENGINE_PACKAGES[@]}"; do
    dir="$ROOT/packages/$package/Sources"
    [[ -d "$dir" ]] || continue
    files=()
    while IFS= read -r file; do files+=("$file"); done < <(grep -RlE --include='*.swift' 'make(Compute|Blit|Render)CommandEncoder\(' "$dir" || true)
    [[ ${#files[@]} -gt 0 ]] || continue
    if matches=$(awk "$OPEN_ENCODER_THROWS" "${files[@]}") && [[ -n "$matches" ]]; then
        echo "A throw while an encoder is open in $package (use withComputeEncoder):"
        echo "$matches"
        echo
        failed=1
    fi
done

# Colour math has one Swift copy, in RedlampColor (SRGB, Luma, OKLab), beside the kernels' in
# Metal: the sRGB transfer functions' thresholds, the Rec.2020 and Rec.709 luma weights and
# OKLab's matrices. These known exceptions (file, reason) keep their own.
COLOR_MATH='0\.04045|0\.0031308|0\.2627|0\.2126|0\.4122214708|0\.6167557872|0\.2104542553|0\.3963377774|2\.1399067357|4\.0767416621'
OWN_COLOR_MATH=(
    "RedlampEngineAPI/Sources/PointColor.swift|OKLCh's swatch colour, for the UI, which can't import RedlampColor"
    "RedlampMasking/Sources/RemovalRegion.swift|removal's, left to the removal work (RM-*)"
    "RedlampEngine/Sources/RedlampEngine+GenerativeFill.swift|generative fill's, left to the removal work (RM-*)"
    "RedlampEngine/Sources/XTransDemosaic.swift|Markesteijn's sRGB-to-XYZ matrix for its CIELab homogeneity map, at LibRaw's precision (CAM-07)"
)
own_color_math() {
    local match=$1 entry
    for entry in "${OWN_COLOR_MATH[@]}"; do
        [[ "${match%%:*}" == */packages/${entry%%|*} ]] && return 0
    done
    return 1
}
matches=""
while IFS= read -r match; do
    own_color_math "$match" || matches+="$match"$'\n'
done < <(grep -RInE --include='*.swift' "$COLOR_MATH" "$ROOT"/packages/*/Sources "$ROOT"/apps/*/Sources \
    | grep -v "/packages/RedlampColor/" || true)
if [[ -n "$matches" ]]; then
    echo "Colour math outside RedlampColor (use SRGB, Luma or OKLab):"
    printf '%s' "$matches"
    echo
    failed=1
fi

if [[ $failed -ne 0 ]]; then
    exit 1
fi
echo "check-engine-purity: OK"
