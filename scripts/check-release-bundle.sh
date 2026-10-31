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
# --app-store checks the Mac App Store build (ARC-22) as well, and fails when:
#
# - it holds Sparkle.framework or Sparkle's licence, RedlampAutomation.framework,
#   RedlampBench.framework or Contents/Helpers (the CLI), which that build leaves out (DEC-90);
# - it lacks a licence text Help › Acknowledgements shows: each in the app's
#   Resources/Acknowledgements but Sparkle's (ARC-25);
# - an executable, the app's or a helper's, isn't signed with com.apple.security.app-sandbox;
# - the app's or an XPC service's version isn't three integers (DEC-92);
# - the app has no PrivacyInfo.xcprivacy, or its Info.plist no ITSAppUsesNonExemptEncryption;
# - an Info.plist holds an SU… (Sparkle) or RedlampFirmware… key (DEC-89);
# - a file in the bundle names ko-fi.com, a link to outside payment (guideline 3.1.1(a)).
#
# Until the work that settles them lands, each of three can be let through, saying so:
# --allow-unsandboxed (ARC-17), --allow-no-privacy-manifest (ARC-24), --allow-donation-link (UX-50).
#
#   scripts/check-release-bundle.sh build/release/Redlamp.app [build/release/dSYMs]
#   scripts/check-release-bundle.sh --app-store [--allow-…] <app> [dsyms]

set -euo pipefail

BUDGET_KB=70000
OWN_EXPORTS='^(_\$s|_OBJC_(METACLASS_|CLASS_)\$_|_RedlampServicesVersion)'
USAGE="usage: check-release-bundle.sh [--app-store [--allow-unsandboxed] [--allow-no-privacy-manifest] [--allow-donation-link]] <app> [dsyms]"

APP_STORE=0
ALLOW_UNSANDBOXED=0
ALLOW_NO_PRIVACY_MANIFEST=0
ALLOW_DONATION_LINK=0
positional=()
for argument in "$@"; do
    case "$argument" in
        --app-store) APP_STORE=1 ;;
        --allow-unsandboxed) ALLOW_UNSANDBOXED=1 ;;
        --allow-no-privacy-manifest) ALLOW_NO_PRIVACY_MANIFEST=1 ;;
        --allow-donation-link) ALLOW_DONATION_LINK=1 ;;
        -*) echo "error: unknown option $argument; $USAGE" >&2; exit 1 ;;
        *) positional+=("$argument") ;;
    esac
done
if [ "$APP_STORE" = 0 ] && [ $((ALLOW_UNSANDBOXED + ALLOW_NO_PRIVACY_MANIFEST + ALLOW_DONATION_LINK)) -gt 0 ]; then
    echo "error: the --allow options go with --app-store; $USAGE" >&2
    exit 1
fi
APP="${positional[0]:-}"
[ -n "$APP" ] || { echo "$USAGE" >&2; exit 1; }
DSYMS="${positional[1]:-}"
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
if [ "$APP_STORE" = 1 ]; then
    excluded=()
    for name in Sparkle.framework Sparkle-MIT.txt RedlampAutomation.framework RedlampBench.framework; do
        while IFS= read -r -d '' found; do
            excluded+=("${found#"$APP"/}")
        done < <(find "$APP" -name "$name" -print0)
    done
    [ ! -e "$APP/Contents/Helpers" ] || excluded+=("Contents/Helpers")
    if [ "${#excluded[@]}" -gt 0 ]; then
        echo "error: the App Store build holds what it leaves out (DEC-90, guidelines 2.3.1(a) and 2.4.5(vii)):" >&2
        printf '  %s\n' "${excluded[@]}" >&2
        failed=1
    fi

    unbundled=()
    for text in "$(dirname "$0")"/../apps/RedlampMac/Resources/Acknowledgements/*.txt; do
        name="$(basename "$text")"
        [ "$name" = Sparkle-MIT.txt ] || [ -f "$APP/Contents/Resources/$name" ] || unbundled+=("$name")
    done
    if [ "${#unbundled[@]}" -gt 0 ]; then
        echo "error: the App Store build lacks licence texts Help › Acknowledgements shows (ARC-25):" >&2
        printf '  %s\n' "${unbundled[@]}" >&2
        failed=1
    fi

    unsandboxed=()
    while IFS= read -r -d '' file; do
        file -b "$file" | grep -q 'Mach-O.* executable' || continue
        # plutil reads the key's dots as a path, so plistlib reads it.
        sandboxed="$(codesign -d --entitlements - --xml "$file" 2>/dev/null | python3 -c '
import plistlib, sys
data = sys.stdin.buffer.read()
print(bool(data.strip()) and plistlib.loads(data).get("com.apple.security.app-sandbox") is True)' || true)"
        [ "$sandboxed" = True ] || unsandboxed+=("${file#"$APP"/}")
    done < <(find "$APP" -type f -perm -u+x -print0)
    if [ "${#unsandboxed[@]}" -gt 0 ]; then
        if [ "$ALLOW_UNSANDBOXED" = 1 ]; then
            echo "warning: let through by --allow-unsandboxed until ARC-17: ${#unsandboxed[@]} executables without com.apple.security.app-sandbox:" >&2
            printf '  %s\n' "${unsandboxed[@]}" >&2
        else
            echo "error: every executable in an App Store app must be sandboxed; these aren't signed with com.apple.security.app-sandbox:" >&2
            printf '  %s\n' "${unsandboxed[@]}" >&2
            failed=1
        fi
    fi

    versions=()
    for bundle in "$APP" "$APP"/Contents/XPCServices/*.xpc; do
        [ -f "$bundle/Contents/Info.plist" ] || continue
        version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || versions+=("${version:-none}: $(basename "$bundle")")
    done
    if [ "${#versions[@]}" -gt 0 ]; then
        echo "error: App Store versions are three integers (DEC-92); these CFBundleShortVersionStrings aren't:" >&2
        printf '  %s\n' "${versions[@]}" >&2
        failed=1
    fi

    INFO="$APP/Contents/Info.plist"
    if ! /usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$INFO" >/dev/null 2>&1; then
        echo "error: the app's Info.plist has no ITSAppUsesNonExemptEncryption, which App Store Connect asks for at every upload" >&2
        failed=1
    fi
    if [ ! -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]; then
        if [ "$ALLOW_NO_PRIVACY_MANIFEST" = 1 ]; then
            echo "warning: let through by --allow-no-privacy-manifest until ARC-24: the app has no Contents/Resources/PrivacyInfo.xcprivacy" >&2
        else
            echo "error: the app has no privacy manifest, Contents/Resources/PrivacyInfo.xcprivacy (ARC-24)" >&2
            failed=1
        fi
    fi

    keys=()
    while IFS= read -r -d '' plist; do
        while read -r key; do
            keys+=("$key: ${plist#"$APP"/}")
        done < <(python3 -c 'import plistlib, sys; print("\n".join(plistlib.load(open(sys.argv[1], "rb"))))' "$plist" \
            | grep -E '^(SU|RedlampFirmware)' || true)
    done < <(find "$APP" -name Info.plist -type f -print0)
    if [ "${#keys[@]}" -gt 0 ]; then
        echo "error: the App Store build carries Sparkle's or the firmware model's keys (DEC-89, guideline 2.4.5(vii)):" >&2
        printf '  %s\n' "${keys[@]}" >&2
        failed=1
    fi

    donations=()
    while IFS= read -r file; do
        donations+=("${file#"$APP"/}")
    done < <(grep -rlaF ko-fi.com "$APP" || true)
    if [ "${#donations[@]}" -gt 0 ]; then
        if [ "$ALLOW_DONATION_LINK" = 1 ]; then
            echo "warning: let through by --allow-donation-link until UX-50: ${#donations[@]} files name ko-fi.com:" >&2
            printf '  %s\n' "${donations[@]}" >&2
        else
            echo "error: these files name ko-fi.com, a link to outside payment that App Review rejects (guideline 3.1.1(a)):" >&2
            printf '  %s\n' "${donations[@]}" >&2
            failed=1
        fi
    fi
fi
size_kb="$(du -sk "$APP" | cut -f1)"
if [ "$size_kb" -gt "$BUDGET_KB" ]; then
    echo "error: the app is $size_kb KB, over its budget of $BUDGET_KB KB. If the growth is wanted," >&2
    echo "       raise BUDGET_KB in scripts/check-release-bundle.sh, giving the reason in the commit." >&2
    failed=1
fi
[ "$failed" = 0 ] || exit 1
echo "==> All $checked Mach-O files are arm64 only and stripped${DSYMS:+, each with its dSYM}; the app is $size_kb KB of $BUDGET_KB."
[ "$APP_STORE" = 0 ] || echo "==> It's shaped for the App Store: none of what that build leaves out, its licence texts, a numeric version and the encryption key."
