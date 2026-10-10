#!/usr/bin/env python3
"""Focus ring gate: Redlamp draws no focus rings, and a new screen can't bring them back.

FocusRings (packages/RedlampUI/Sources/DesignSystem/FocusRings.swift), which the Mac app
installs at launch, takes AppKit's ring off whatever has focus, in every window. SwiftUI draws
focus effects of its own, which are turned off where each SwiftUI hierarchy is hosted. This
fails on:

- an NSHostingView or NSHostingController whose root view doesn't end in focusEffectDisabled(),
- a scene (Window, WindowGroup, Settings and the rest) whose content doesn't,
- code that turns a ring back on: focusRingType set to .default or .exterior, or
  focusEffectDisabled(false),
- a Mac app that no longer installs FocusRings.

It reads the packages' sources and the Mac app's. A hosting view that only measures a view, and
is never shown, is listed in MEASURING with the reason. .cursor/rules/focus-rings.mdc has the rule.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "apps/RedlampMac/Sources"
SOURCES = [*sorted(ROOT.glob("packages/*/Sources")), APP]

# Hosting views never shown: (file, text on the line that makes it, why).
MEASURING = [
    ("packages/RedlampDesign/Sources/Controls/Symbol.swift", "NSHostingView(rootView: Image(", "measures a symbol's size"),
]

HOSTING = re.compile(r"\bNSHosting(?:View|Controller)(?:<[^<>()]*>)?[ \t]*\(")
SCENE = re.compile(r"\b(?:WindowGroup|Window|UtilityWindow|Settings|MenuBarExtra|DocumentGroup)[ \t]*[({]")
RINGS_ON = re.compile(
    r"\bfocusRingType\s*=\s*(?:NSFocusRingType)?\.(?:default|exterior)\b|\.focusEffectDisabled\(\s*false\s*\)"
)
DISABLED = re.compile(r"\.focusEffectDisabled\(\s*\)")
INSTALLED = re.compile(r"\bFocusRings\.removeEverywhere\(\s*\)")
OPENING = {"(": ")", "[": "]", "{": "}"}
STRING_START = re.compile(r'(#*)("""|")')


def code_only(text: str) -> str:
    """The text with comments and string literals blanked (interpolated code kept), newlines kept."""
    out = list(text)
    stack: list[list] = []  # ["string", hashes, multiline] or ["code", parentheses open]

    def blank(start: int, end: int) -> None:
        for k in range(start, min(end, len(out))):
            if out[k] != "\n":
                out[k] = " "

    i, n = 0, len(text)
    while i < n:
        top = stack[-1] if stack else None
        if top and top[0] == "string":
            close = ('"""' if top[2] else '"') + "#" * top[1]
            escape = "\\" + "#" * top[1]
            if text.startswith(close, i):
                blank(i, i + len(close))
                stack.pop()
                i += len(close)
            elif text.startswith(escape, i):
                after = i + len(escape)
                if after < n and text[after] == "(":
                    stack.append(["code", 1])
                blank(i, after + 1)
                i = after + 1
            else:
                blank(i, i + 1)
                i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
            continue
        if text.startswith("/*", i):
            depth, j = 0, i
            while j < n:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                    if depth == 0:
                        break
                else:
                    j += 1
            blank(i, j)
            i = j
            continue
        string = STRING_START.match(text, i)
        if string:
            stack.append(["string", len(string.group(1)), string.group(2) == '"""'])
            blank(i, string.end())
            i = string.end()
            continue
        if top and top[0] == "code":
            if text[i] == "(":
                top[1] += 1
            elif text[i] == ")":
                top[1] -= 1
                if top[1] == 0:
                    stack.pop()
                    blank(i, i + 1)
        i += 1
    return "".join(out)


def closing(code: str, start: int) -> int:
    """The index of the bracket that closes the one at `start`."""
    depth = 0
    for i in range(start, len(code)):
        if code[i] in OPENING:
            depth += 1
        elif code[i] in OPENING.values():
            depth -= 1
            if depth == 0:
                return i
    return len(code)


def top_level(code: str) -> str:
    """`code` with whatever is inside its brackets blanked."""
    out, depth = [], 0
    for c in code:
        if c in OPENING.values():
            depth -= 1
        out.append(c if depth == 0 or c == "\n" else " ")
        if c in OPENING:
            depth += 1
    return "".join(out)


def root_view(arguments: str) -> str:
    """The `rootView:` argument of a hosting view's initialiser, out of an AnyView if it's in one."""
    flat = top_level(arguments)
    label = flat.find("rootView:")
    start = 0 if label < 0 else label + len("rootView:")
    comma = flat.find(",", start)
    root = arguments[start : len(arguments) if comma < 0 else comma].strip()
    if root.startswith("AnyView(") and closing(root, len("AnyView")) == len(root) - 1:
        root = root[len("AnyView(") : -1]
    return root


def disabled(expression: str) -> bool:
    return bool(DISABLED.search(top_level(expression)))


def main() -> int:
    hosting: list[str] = []
    scenes: list[str] = []
    rings_on: list[str] = []
    installed = False
    measured: set[int] = set()
    counted = [0, 0]
    for source in SOURCES:
        for path in sorted(source.rglob("*.swift")):
            text = path.read_text(errors="replace")
            if not any(word in text for word in ("NSHosting", "some Scene", "focusRingType", "focusEffectDisabled", "FocusRings")):
                continue
            code = code_only(text)
            relative = path.relative_to(ROOT).as_posix()
            lines = text.splitlines()

            def where(offset: int) -> str:
                number = code.count("\n", 0, offset) + 1
                return f"{relative}:{number}: {lines[number - 1].strip()}"

            for match in HOSTING.finditer(code):
                counted[0] += 1
                open_at = match.end() - 1
                if disabled(root_view(code[open_at + 1 : closing(code, open_at)])):
                    continue
                line = where(match.start())
                allowance = next((k for k, (file, snippet, _) in enumerate(MEASURING)
                                  if k not in measured and file == relative and snippet in line), None)
                if allowance is None:
                    hosting.append(line)
                else:
                    measured.add(allowance)
            if "some Scene" in code:
                for match in SCENE.finditer(code):
                    counted[1] += 1
                    at = match.end() - 1
                    if code[at] == "(":
                        at = closing(code, at) + 1
                        while at < len(code) and code[at].isspace():
                            at += 1
                    if at < len(code) and code[at] == "{" and disabled(code[at + 1 : closing(code, at)]):
                        continue
                    scenes.append(where(match.start()))
            rings_on += [where(match.start()) for match in RINGS_ON.finditer(code)]
            installed = installed or (path.is_relative_to(APP) and bool(INSTALLED.search(code)))

    failed = False
    for problems, title in [
        (hosting, "NSHostingView or NSHostingController whose root view doesn't end in .focusEffectDisabled()"),
        (scenes, "Scene whose content doesn't end in .focusEffectDisabled()"),
        (rings_on, "Focus ring turned back on"),
    ]:
        if problems:
            print(f"{title}:")
            print("\n".join(problems))
            print()
            failed = True
    if not installed:
        print("The Mac app doesn't call FocusRings.removeEverywhere() (apps/RedlampMac/Sources/RedlampApp.swift).")
        print()
        failed = True
    if failed:
        print("Redlamp draws no focus rings (.cursor/rules/focus-rings.mdc). End each hosted root view and each")
        print("scene's content in .focusEffectDisabled(), as NSHostingView(rootView: Panel().focusEffectDisabled()).")
        return 1
    print(f"check-focus-rings: OK ({counted[0]} hosting views, {counted[1]} scenes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
