"""Reads the app's own definitions, so the manual's reference tables are never typed by hand.

- Sliders: `ParameterCatalog` in packages/RedlampEngineAPI/Sources/ParameterSpec.swift, each
  `ParameterSpec(.id, "Label", range:, default:, step:, format:)` with the initialiser's defaults
  (-100 ... 100, 0, step 1, a signed integer) where an argument is left out.
- Shortcuts: `ShortcutAction` in packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift: each
  action's title, keys and category, with keys drawn as `KeyCombo.keys` draws them.

Both files are read as text, so the reader breaks loudly if their shape changes: a table that
comes out empty fails the build rather than printing nothing.
"""

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

PARAMETERS = "packages/RedlampEngineAPI/Sources/ParameterSpec.swift"
SHORTCUTS = "packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift"


@dataclass
class Parameter:
    id: str
    label: str
    low: float
    high: float
    default: float
    step: float
    format: str
    digits: int

    def show(self, value: float) -> str:
        """The value as the slider's field shows it (`ParameterSpec.formatted`)."""
        if self.format in ("signedInteger", "integer"):
            text = f"{round(value):d}"
            if self.format == "signedInteger" and value > 0:
                text = "+" + text
        elif self.format == "kelvin":
            text = f"{int(round(value / 50) * 50)}"
        else:
            text = f"{value:.{self.digits}f}"
            if self.format == "signedDecimal" and value > 0.5 / 10**self.digits:
                text = "+" + text
        return text.replace("-", "−")


@dataclass
class Shortcut:
    id: str
    title: str
    category: str
    keys: list[list[str]]
    accepts_shift: bool


def source_commit(root: Path, *paths: str) -> str:
    """The last commit that changed any of `paths`, short, with its date."""
    out = subprocess.run(
        ["git", "log", "-1", "--format=%h %cs", "--", *paths], cwd=root, capture_output=True, text=True, check=True
    )
    return out.stdout.strip()


def _calls(text: str, name: str):
    """The argument text of each `name(…)` call, with nested parentheses kept whole."""
    start = 0
    while (start := text.find(name + "(", start)) >= 0:
        depth, i = 0, start + len(name)
        while True:
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            if depth == 0:
                break
            i += 1
        yield text[start + len(name) + 1 : i]
        start = i


def parameters(root: Path) -> dict[str, Parameter]:
    text = (root / PARAMETERS).read_text()
    catalog = text[text.index("public enum ParameterCatalog") :]
    found: dict[str, Parameter] = {}
    for arguments in _calls(catalog, "ParameterSpec"):
        match = re.match(r'\s*\.(\w+),\s*"([^"]+)"(.*)', arguments, re.S)
        if not match:
            continue
        id_, label, rest = match.groups()
        low, high = -100.0, 100.0
        if r := re.search(r"range:\s*(-?[\d.]+)\s*\.\.\.\s*(-?[\d.]+)", rest):
            low, high = float(r.group(1)), float(r.group(2))
        default = float(d.group(1)) if (d := re.search(r"default:\s*(-?[\d.]+)", rest)) else 0.0
        step = float(s.group(1)) if (s := re.search(r"step:\s*([\d.]+)", rest)) else 1.0
        format_, digits = "signedInteger", 0
        if f := re.search(r"format:\s*\.(\w+)(?:\((\d+)\))?", rest):
            format_, digits = f.group(1), int(f.group(2) or 0)
        found[id_] = Parameter(id_, label, low, high, default, step, format_, digits)
    if len(found) < 100:
        raise SystemExit(f"error: read only {len(found)} parameters from {PARAMETERS}; has its shape changed?")
    return found


def _switch(text: str, header: str) -> str:
    """The body of the `switch self` under `header` (a property declaration)."""
    start = text.index(header)
    body = text[start : text.index("\n    }\n", start)]
    return re.sub(r"//[^\n]*", "", body)


def _cases(body: str) -> list[tuple[list[str], str]]:
    """`case .a, .b: value` arms, joined across lines, as ([ids], value)."""
    arms = []
    for match in re.finditer(r"case\s+((?:\.\w+\s*,\s*)*\.\w+)\s*:\s*(.*?)(?=\n\s*case\s|\n\s*default|\Z)", body, re.S):
        ids = re.findall(r"\.(\w+)", match.group(1))
        value = re.sub(r"\s*\}$", "", " ".join(match.group(2).split()))
        arms.append((ids, value))
    return arms


NAMED_KEYS = {
    "tab": "Tab",
    "escape": "Esc",
    "delete": "⌫",
    "space": "Space",
    "left": "←",
    "right": "→",
    "up": "↑",
    "down": "↓",
}


def _combo(source: str) -> list[str]:
    """One `.char(…)` or `KeyCombo(…)` as `KeyCombo.keys` lists it: modifiers ⌥ ⇧ ⌘, then the key."""
    keys = []
    if "option: true" in source:
        keys.append("⌥")
    if "shift: true" in source:
        keys.append("⇧")
    if "command: true" in source:
        keys.append("⌘")
    if c := re.match(r'\.char\("(.*?)"', source):
        character = c.group(1).replace("\\\\", "\\")
        keys.append("Space" if character == " " else character.upper())
    elif f := re.search(r"\.function\((\d+)\)", source):
        keys.append(f"F{f.group(1)}")
    elif n := re.match(r"KeyCombo\(\.(\w+)", source):
        keys.append(NAMED_KEYS[n.group(1)])
    else:
        raise SystemExit(f"error: can't read the key combo {source!r} in {SHORTCUTS}")
    return keys


def shortcuts(root: Path) -> list[Shortcut]:
    text = (root / SHORTCUTS).read_text()
    categories = dict(re.findall(r'case (\w+) = "([^"]+)"', text[text.index("enum ShortcutCategory") :]))
    order = re.findall(r"case ([\w, ]+)\n", text[text.index("public enum ShortcutAction") : text.index("public var id")])
    ids = [name.strip() for line in order for name in line.split(",") if name.strip()]
    titles = {i: v.strip('"') for ids_, v in _cases(_switch(text, "public var title")) for i in ids_}
    category = {i: categories[v.lstrip(".")] for ids_, v in _cases(_switch(text, "public var category")) for i in ids_}
    combos: dict[str, list[list[str]]] = {}
    for ids_, value in _cases(_switch(text, "public var defaultCombos")):
        inner = value.strip()[1:-1].strip()
        parts = [p.strip() for p in re.split(r",\s*(?=\.char|KeyCombo)", inner) if p.strip()]
        for i in ids_:
            combos[i] = [_combo(p) for p in parts]
    shift_body = _switch(text, "public var acceptsShift")
    shifted = set(re.findall(r"\.(\w+)", shift_body[: shift_body.index("true")]))
    found = [Shortcut(i, titles[i], category[i], combos.get(i, []), i in shifted) for i in ids]
    if len(found) < 60 or not any(s.keys for s in found):
        raise SystemExit(f"error: read only {len(found)} shortcuts from {SHORTCUTS}; has its shape changed?")
    return found
