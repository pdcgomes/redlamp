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
)
UI_PACKAGES=(
    RedlampCanvas
    RedlampDesign
    RedlampUI
)

FORBIDDEN_IN_ENGINE='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(AppKit|UIKit|SwiftUI|Cocoa|RedlampUI|RedlampCanvas|RedlampDesign)\b'
FORBIDDEN_IN_UI='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(RedlampEngine|RedlampKernels|RedlampColor|RedlampServices|RedlampMasking)\b'

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

if [[ $failed -ne 0 ]]; then
    exit 1
fi
echo "check-engine-purity: OK"
