"""Tables generated from the app's code, placed with `{{table: name arguments…}}`.

- `{{table: sliders id id …}}`: each slider's label, range, default and arrow-key step, from
  `ParameterCatalog`, in the order given.
- `{{table: shortcuts id @Category …}}`: each action's keys and title, from `ShortcutAction`;
  `@Masking` adds every action in that category (its name as `ShortcutCategory` spells it).

Each table ends with a line naming the file it was generated from and the commit that last
changed it.
"""

import html
from pathlib import Path

import catalog


class Tables:
    def __init__(self, root: Path):
        self.root = root
        self._parameters = None
        self._shortcuts = None

    @property
    def parameters(self):
        if self._parameters is None:
            self._parameters = catalog.parameters(self.root)
        return self._parameters

    @property
    def shortcuts(self):
        if self._shortcuts is None:
            self._shortcuts = catalog.shortcuts(self.root)
        return self._shortcuts

    def render(self, name: str, arguments: list[str]) -> str:
        if name == "sliders":
            return self.sliders(arguments)
        if name == "shortcuts":
            return self.keys(arguments)
        raise SystemExit(f"error: no generated table called {name!r}")

    def _generated(self, path: str) -> str:
        commit = catalog.source_commit(self.root, path)
        return f'<p class="generated">Generated from <code>{Path(path).name}</code> at commit {html.escape(commit)}.</p>'

    def sliders(self, ids: list[str]) -> str:
        rows = []
        for id_ in ids:
            if id_ not in self.parameters:
                raise SystemExit(f"error: no slider {id_!r} in {catalog.PARAMETERS}")
            p = self.parameters[id_]
            step = p.show(p.step).lstrip("+")
            rows.append(
                f"<tr><td>{html.escape(p.label)}</td><td class='num'>{p.show(p.low)} to {p.show(p.high)}</td>"
                f"<td class='num'>{p.show(p.default)}</td><td class='num'>{step}</td></tr>"
            )
        return (
            '<div class="generated-table"><table class="sliders">'
            "<thead><tr><th>Slider</th><th>Range</th><th>Default</th><th>Arrow-key step</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody></table>{self._generated(catalog.PARAMETERS)}</div>"
        )

    def keys(self, selectors: list[str]) -> str:
        by_id = {s.id: s for s in self.shortcuts}
        chosen = []
        for selector in selectors:
            if selector.startswith("@"):
                category = selector[1:].replace("_", " ")
                matches = [s for s in self.shortcuts if s.category == category]
                if not matches:
                    raise SystemExit(f"error: no shortcut category {category!r} in {catalog.SHORTCUTS}")
                chosen += matches
            elif selector in by_id:
                chosen.append(by_id[selector])
            else:
                raise SystemExit(f"error: no shortcut action {selector!r} in {catalog.SHORTCUTS}")
        rows = []
        for s in chosen:
            if not s.keys:
                continue
            combos = '<span class="or">or</span>'.join(
                "".join(f"<kbd>{html.escape(k)}</kbd>" for k in combo) for combo in s.keys
            )
            rows.append(f"<tr><td class='keys'>{combos}</td><td>{html.escape(s.title)}</td></tr>")
        return (
            '<div class="generated-table"><table class="shortcuts">'
            "<thead><tr><th>Keys</th><th>Action</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody></table>{self._generated(catalog.SHORTCUTS)}</div>"
        )
