#!/usr/bin/env bash
#
# Fails when an app bundle isn't shaped for release:
#
# - any Mach-O holds anything but arm64: Redlamp runs on Apple Silicon only, so an Intel
#   slice is size the download carries for nothing;
# - any Mach-O still carries debugging symbols, which belong in the dSYMs;
# - given the dSYMs' folder, a Mach-O built here has no dSYM of the same UUID, so its
#   crash reports couldn't be symbolicated (Sparkle's come built and ship none);
# - RedlampServices exports anything but its Swift and Objective-C symbols: LibRaw, linked in
#   statically, is built hidden so dead-stripping can drop what Redlamp doesn't call;
# - an XPC service carries its own copy of a framework the app has, which it loads from the
#   app's Frameworks instead;
# - a helper in Contents/Helpers (the CLI) links a framework the app doesn't embed, so it
#   can't start;
# - the bundle outgrows its budget, 2% above what it measured when the budget was set.
#
#   scripts/check-release-bundle.sh build/release/Redlamp.app [build/release/dSYMs]

set -euo pipefail

BUDGET_KB=60000
OWN_EXPORTS='^(_\$s|_OBJC_(METACLASS_|CLASS_)\$_|_RedlampServicesVersion)'

APP="${1:?usage: check-release-bundle.sh <app> [dsyms]}"
DSYMS="${2:-}"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
[ -z "$DSYMS" ] || [ -d "$DSYMS" ] || { echo "error: no dSYMs at $DSYMS" >&2; exit 1; }

dsym_uuids=""
[ -z "$DSYMS" ] || dsym_uuids="$(find "$DSYMS" -name '*.dSYM' -maxdepth 1 -exec dwarfdump --uuid {} + | awk '{print $2}')"

checked=0
wrong=()
symbols=()
undocumented=()
exporting=()
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q Mach-O || continue
    checked=$((checked + 1))
    name="${file#"$APP"/}"
    archs="$(lipo -archs "$file")"
    [ "$archs" = arm64 ] || wrong+=("$archs: $name")
    # The linker marks every binary with an OPT entry, stripped or not.
    stabs="$(nm -a "$file" 2>/dev/null | awk '$2 == "-" && $5 != "OPT"' | wc -l | tr -d ' ')"
    [ "$stabs" = 0 ] || symbols+=("$stabs: $name")
    if [[ "$name" == */RedlampServices.framework/Versions/A/RedlampServices ]]; then
        exports="$(nm -gU "$file" | awk '{print $3}' | grep -cvE "$OWN_EXPORTS" || true)"
        [ "$exports" = 0 ] || exporting+=("$exports: $name")
    fi
    if [ -n "$DSYMS" ] && [[ "$name" != */Sparkle.framework/* ]]; then
        while read -r uuid; do
            grep -qx "$uuid" <<<"$dsym_uuids" || undocumented+=("$uuid: $name")
        done < <(dwarfdump --uuid "$file" | awk '{print $2}')
    fi
done < <(find "$APP" -type f -print0)

failed=0
if [ "${#wrong[@]}" -gt 0 ]; then
    echo "error: ${#wrong[@]} of $checked Mach-O files aren't arm64 only:" >&2
    printf '  %s\n' "${wrong[@]}" >&2
    failed=1
fi
if [ "${#symbols[@]}" -gt 0 ]; then
    echo "error: ${#symbols[@]} of $checked Mach-O files carry debugging symbols (count: file):" >&2
    printf '  %s\n' "${symbols[@]}" >&2
    failed=1
fi
if [ "${#undocumented[@]}" -gt 0 ]; then
    echo "error: ${#undocumented[@]} binaries have no dSYM in $DSYMS:" >&2
    printf '  %s\n' "${undocumented[@]}" >&2
    failed=1
fi
if [ "${#exporting[@]}" -gt 0 ]; then
    echo "error: RedlampServices exports LibRaw's symbols (count: file); build LibRaw hidden:" >&2
    printf '  %s\n' "${exporting[@]}" >&2
    failed=1
fi
copies=()
for framework in "$APP"/Contents/XPCServices/*.xpc/Contents/Frameworks/*.framework; do
    [ -d "$framework" ] || continue
    [ ! -d "$APP/Contents/Frameworks/$(basename "$framework")" ] || copies+=("${framework#"$APP"/}")
done
if [ "${#copies[@]}" -gt 0 ]; then
    echo "error: XPC services carry copies of the app's frameworks:" >&2
    printf '  %s\n' "${copies[@]}" >&2
    failed=1
fi
# A function, since bash 3.2 misreads parentheses inside a quoted program in <( ).
rpath_frameworks() { otool -L "$1" | awk -F/ '$1 ~ /@rpath$/ { print $2 }'; }
missing=()
for tool in "$APP"/Contents/Helpers/*; do
    [ -f "$tool" ] || continue
    while read -r framework; do
        [ -d "$APP/Contents/Frameworks/$framework" ] || missing+=("$framework: ${tool#"$APP"/}")
    done < <(rpath_frameworks "$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: the helpers link frameworks the app doesn't embed; add them to the app's dependencies:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    failed=1
fi
size_kb="$(du -sk "$APP" | cut -f1)"
if [ "$size_kb" -gt "$BUDGET_KB" ]; then
    echo "error: the app is $size_kb KB, over its budget of $BUDGET_KB KB. If the growth is wanted," >&2
    echo "       raise BUDGET_KB in scripts/check-release-bundle.sh, giving the reason in the commit." >&2
    failed=1
fi
[ "$failed" = 0 ] || exit 1
echo "==> All $checked Mach-O files are arm64 only and stripped${DSYMS:+, each with its dSYM}; the app is $size_kb KB of $BUDGET_KB."
