"""The manual's Markdown: CommonMark with tables and definition lists, plus

- keys: `[[⇧W]]` is a keycap, `[[⌘]]+[[K]]` two of them;
- callouts: `::: note`, `::: lightroom`, `::: tip`, `::: caution`, `::: not-yet`, each with an
  optional label of its own after the kind (`::: note On a large photo`), closed by `:::`;
- directives on a line of their own: `{{figure: name}}` places docs/manual/figures/name.html,
  `{{table: name arguments…}}` a table generated from the app's code (tables.py);
- cross-references: a link to `#id` gets its page number, and an empty one, `[](#id)`, also its
  label, such as 3.2 or Fig. 3.1 (filled in by layout.py once every id is known).

Section files open with TOML front matter between `+++` lines: `deck` (the italic summary under
the title) and `sources` (the files the section was written from).
"""

import html
import re
import tomllib

from markdown_it import MarkdownIt
from mdit_py_plugins.attrs import attrs_block_plugin
from mdit_py_plugins.container import container_plugin
from mdit_py_plugins.deflist import deflist_plugin

KEY = re.compile(r"\[\[([^\[\]]+?)\]\]")
DIRECTIVE = re.compile(r"^\{\{\s*(figure|table)\s*:\s*([^}]+?)\s*\}\}[ \t]*$", re.M)
CALLOUTS = {
    "note": "Note",
    "tip": "Tip",
    "lightroom": "Coming from Lightroom",
    "caution": "Caution",
    "not-yet": "Not yet",
}


def _callout(kind: str, default_label: str):
    def render(self, tokens, idx, options, env):
        token = tokens[idx]
        if token.nesting == 1:
            label = token.info.strip()[len(kind) :].strip() or default_label
            return f'<aside class="callout callout-{kind}"><div class="callout-label">{html.escape(label)}</div>\n'
        return "</aside>\n"

    return render


def parser() -> MarkdownIt:
    md = MarkdownIt("commonmark", {"html": True, "typographer": True})
    md.enable(["table", "strikethrough", "replacements", "smartquotes"])
    md.use(deflist_plugin)
    md.use(attrs_block_plugin)
    for kind, label in CALLOUTS.items():
        md.use(container_plugin, name=kind, render=_callout(kind, label))
    return md


def front_matter(text: str) -> tuple[dict, str]:
    if not text.startswith("+++\n"):
        return {}, text
    end = text.index("\n+++\n", 4)
    return tomllib.loads(text[4:end]), text[end + 5 :]


MODIFIERS = "⌃⌥⇧⌘"


def keys(text: str) -> str:
    """Keycaps, one per key with the modifiers first, as the app's Keyboard Shortcuts sheet draws them."""

    def caps(match: re.Match) -> str:
        combo = match.group(1)
        split = [c for c in combo if c in MODIFIERS]
        key = combo[len(split) :] if combo[: len(split)] == "".join(split) else ""
        parts = split + [key] if key else [combo]
        if len(parts) == 1:
            return f"<kbd>{html.escape(parts[0])}</kbd>"
        return '<span class="keys">' + "".join(f"<kbd>{html.escape(p)}</kbd>" for p in parts) + "</span>"

    return KEY.sub(caps, text)


def render(md: MarkdownIt, text: str, directive) -> str:
    """Markdown to HTML; `directive(kind, words)` returns the HTML for a `{{kind: words}}` line.

    A directive's HTML is passed through as one HTML block, which a blank line would end, so
    its blank lines are removed.
    """

    def place(match: re.Match) -> str:
        block = directive(match.group(1), match.group(2).split())
        return "\n" + re.sub(r"\n[ \t]*(?=\n)", "", block.strip()) + "\n"

    return md.render(keys(DIRECTIVE.sub(place, text)))


def inline(md: MarkdownIt, text: str) -> str:
    return md.renderInline(keys(text))


def slug(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", html.unescape(text)).lower()
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-")
