"""Puts the manual together as one HTML document: the cover, the contents, the front matter, each
part's opener and sections, and the reference, numbered with the pages known so far.

docs/manual/book.toml lists every part and section, written or not; a section with a `file` is
written, and the others appear in the contents as the plan for the rest of the book.
"""

import html
import os
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

import catalog
import fonts
import markup
from tables import Tables

MANUAL = Path("docs/manual")
ROMAN = [(10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]


def roman(n: int) -> str:
    out = ""
    for value, letters in ROMAN:
        while n >= value:
            out, n = out + letters, n - value
    return out


def css_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def strip_tags(text: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", text))


@dataclass
class Ref:
    """What a cross-reference to an id says: `label` for an empty link (3.2, Fig. 3.1)."""

    label: str
    paged: bool = True
    written: bool = True


@dataclass
class Section:
    id: str
    title: str
    number: str
    file: str | None = None
    part: "Part | None" = None
    deck: str = ""
    sources: list[str] = field(default_factory=list)
    text: str = ""
    body: str = ""
    headings: list[tuple[int, str, str]] = field(default_factory=list)

    @property
    def page_name(self) -> str:
        return "s-" + re.sub(r"[^a-z0-9]+", "-", self.number.lower())


@dataclass
class Part:
    number: str
    id: str
    title: str
    deck: str
    band: str
    sections: list[Section]

    @property
    def written(self) -> list[Section]:
        return [s for s in self.sections if s.file]

    @property
    def numeral(self) -> str:
        return self.number.zfill(2) if self.number.isdigit() else self.number


class Manual:
    def __init__(self, root: Path, out_dir: Path):
        self.root = root
        self.repo = os.path.relpath(root, out_dir)
        data = tomllib.loads((root / MANUAL / "book.toml").read_text())
        self.meta = data["book"]
        self.meta["commit"], self.meta["date"] = catalog.source_commit(root, "packages", "apps").split()
        self.front = [Section(f["id"], f["title"], f["number"], f.get("file")) for f in data.get("front", [])]
        self.parts = []
        for p in data["part"]:
            part = Part(p["number"], p["id"], p["title"], p.get("deck", ""), p.get("band", "steel"), [])
            for i, s in enumerate(p["sections"], 1):
                part.sections.append(Section(s["id"], s["title"], f"{p['number']}.{i}", s.get("file"), part))
            self.parts.append(part)
        self.md = markup.parser()
        self.tables = Tables(root)
        self.refs: dict[str, Ref] = {"contents": Ref("Contents"), "link-index": Ref("")}
        self._prepare()

    def sections(self) -> list[Section]:
        return self.front + [s for part in self.parts for s in part.sections]

    # ---------------------------------------------------------------- reading the sources

    def _prepare(self) -> None:
        for s in self.sections():
            self.refs[s.id] = Ref(s.number, written=bool(s.file))
            if s.file:
                meta, text = markup.front_matter((self.root / MANUAL / "content" / s.file).read_text())
                s.text = text.replace("{{commit}}", self.meta["commit"]).replace("{{date}}", self.meta["date"])
                s.deck, s.sources = meta.get("deck", ""), meta.get("sources", [])
        for part in self.parts:
            self.refs[part.id] = Ref(f"Part {part.number}")
        for prefix, sections in [("0", self.front)] + [(p.number, p.sections) for p in self.parts]:
            figures = [name for s in sections for name in re.findall(r"^\{\{\s*figure\s*:\s*([\w.-]+)", s.text, re.M)]
            for n, name in enumerate(figures, 1):
                self.refs[f"fig.{name}"] = Ref(f"Fig. {prefix}.{n}", paged=False)
        for s in self.sections():
            if s.text:
                s.body = self._headings(s, markup.render(self.md, s.text, self._directive))

    def figure(self, name: str) -> dict[str, str]:
        """A figure file: `key: value` lines (title, tag, caption, class), `---`, then its HTML."""
        text = (self.root / MANUAL / "figures" / f"{name}.html").read_text()
        head, body = text.split("\n---\n", 1)
        meta = {k.strip(): v.strip() for k, v in (line.split(":", 1) for line in head.strip().splitlines())}
        meta["body"] = body.replace("{{repo}}", self.repo)
        return meta

    def _directive(self, kind: str, words: list[str]) -> str:
        if kind == "table":
            return self.tables.render(words[0], words[1:])
        name = words[0]
        fig = self.figure(name)
        tag = f'<span class="fig-tag">{html.escape(fig["tag"])}</span>' if fig.get("tag") else ""
        classes = " ".join(["fig", *fig.get("class", "").split()])
        return (
            f'<figure class="{classes}" id="fig.{name}"><div class="fig-frame">'
            f'<div class="fig-head"><span class="fig-no">{self.refs[f"fig.{name}"].label}</span>'
            f'<span class="fig-title">{html.escape(fig["title"])}</span>{tag}</div>'
            f'{fig["body"]}</div><figcaption>{markup.inline(self.md, fig.get("caption", ""))}</figcaption></figure>'
        )

    def _headings(self, s: Section, body: str) -> str:
        def anchor(match: re.Match) -> str:
            level, attrs, text = match.group(1), match.group(2), match.group(3)
            if found := re.search(r'id="([^"]+)"', attrs):
                id_ = found.group(1)
            else:
                id_ = f"{s.id}.{markup.slug(text)}"
                attrs += f' id="{id_}"'
            if id_ in self.refs:
                raise SystemExit(f"error: {s.file}: the id {id_} is already used; give the heading an id of its own")
            s.headings.append((int(level), id_, strip_tags(text)))
            self.refs[id_] = Ref(strip_tags(text))
            return f"<h{level}{attrs}>{text}</h{level}>"

        return re.sub(r"<h([23])([^>]*)>(.*?)</h\1>", anchor, body, flags=re.S)

    # ---------------------------------------------------------------- numbering

    def page(self, id_: str, pages: dict[str, int]) -> str:
        """A page number as printed: roman numerals before the first part, as in the front matter."""
        n = pages.get(id_)
        if n is None:
            return "00"
        first = min((pages[p.id] for p in self.parts if p.id in pages), default=1)
        return roman(n) if n < first else str(n)

    def _xrefs(self, body: str, pages: dict[str, int]) -> str:
        def link(match: re.Match) -> str:
            target, text = match.group(1), match.group(2)
            if target not in self.refs:
                raise SystemExit(f"error: a cross-reference to #{target}, which nothing in the manual defines")
            ref = self.refs[target]
            label = text or html.escape(ref.label)
            if not ref.written:
                return f'<span class="xref-planned">{label}</span>'
            page = f'<span class="pref">p.&#8239;{self.page(target, pages)}</span>' if ref.paged else ""
            return f'<a class="xref" href="#{target}">{label}</a>{page}'

        return re.sub(r'<a href="#([^"]+)">(.*?)</a>', link, body, flags=re.S)

    # ---------------------------------------------------------------- pages

    def html(self, pages: dict[str, int], measuring: bool) -> str:
        style = (self.root / MANUAL / "style" / "manual.css").read_text()
        body = [self._cover(), self._contents(pages)]
        body += [self._section(s, pages) for s in self.front if s.file]
        for part in self.parts:
            if part.written:
                body.append(self._opener(part, pages))
                body += [self._section(s, pages) for s in part.written]
        if measuring:
            body.append(self._index())
        return (
            '<!doctype html>\n<html lang="en-GB">\n<head>\n<meta charset="utf-8">\n'
            f"<title>{html.escape(self.meta['title'])}</title>\n"
            f"<style>\n{fonts.css()}\n{style}\n{self._page_rules()}\n</style>\n</head>\n<body>\n"
            + "\n".join(body)
            + "\n</body>\n</html>\n"
        )

    def _page_rules(self) -> str:
        rules = []
        for part in self.parts:
            for s in part.written:
                rules.append(
                    f"@page {s.page_name} {{ @top-left {{ content: {css_string(s.title)}; }} "
                    f"@top-right {{ content: {css_string(part.title)}; }} }}"
                )
        return "\n".join(rules)

    def _cover(self) -> str:
        cover = (self.root / MANUAL / "cover.html").read_text()
        dots = "".join(
            f'<li class="band-{p.band}"><span class="dot"></span>{html.escape(p.title)}</li>' for p in self.parts
        )
        values = {
            "repo": self.repo,
            "parts": dots,
            "title": html.escape(self.meta["title"]),
            "edition": html.escape(self.meta["edition"]),
            "summary": markup.inline(self.md, self.meta["summary"]),
            "commit": html.escape(self.meta.get("commit", "")),
            "date": html.escape(self.meta.get("date", "")),
        }
        return markup.keys(re.sub(r"\{\{(\w+)\}\}", lambda m: values[m.group(1)], cover))

    def _row(self, s: Section, pages: dict[str, int]) -> str:
        if not s.file:
            return (
                f'<li class="toc-row planned"><span class="no">{s.number}</span>'
                f'<span class="t">{html.escape(s.title)}</span></li>'
            )
        return (
            f'<li class="toc-row"><span class="no">{s.number}</span><a class="t" href="#{s.id}">'
            f'{html.escape(s.title)}</a><span class="leader"></span><span class="pg">{self.page(s.id, pages)}</span></li>'
        )

    def _contents(self, pages: dict[str, int]) -> str:
        groups = []
        if any(s.file for s in self.front):
            rows = "".join(self._row(s, pages) for s in self.front if s.file)
            groups.append(f'<div class="toc-group toc-front"><ol>{rows}</ol></div>')
        for part in self.parts:
            rows = "".join(self._row(s, pages) for s in part.sections)
            state = "" if part.written else " planned"
            groups.append(
                f'<div class="toc-group band-{part.band}{state}"><div class="toc-part">'
                f'<span class="chip">{part.number}</span><span class="toc-part-title">{html.escape(part.title)}</span>'
                f"</div><ol>{rows}</ol></div>"
            )
        note = markup.inline(self.md, self.meta.get("contents_note", ""))
        return (
            '<nav class="contents" id="contents"><h1 class="contents-title">Contents</h1>'
            f'<p class="contents-note">{note}</p>{"".join(groups)}</nav>'
        )

    def _opener(self, part: Part, pages: dict[str, int]) -> str:
        items = []
        for s in part.sections:
            page = f'<span class="pg">{self.page(s.id, pages)}</span>' if s.file else ""
            title = f'<a href="#{s.id}">{html.escape(s.title)}</a>' if s.file else f"<span>{html.escape(s.title)}</span>"
            items.append(f'<li class="{"" if s.file else "planned"}"><span class="no">{s.number}</span>{title}{page}</li>')
        return (
            f'<section class="opener band-{part.band}" id="{part.id}"><div class="opener-glow"></div>'
            f'<div class="opener-top"><div class="opener-eyebrow">Part {part.number}</div>'
            f'<h1>{html.escape(part.title)}</h1><p class="deck">{markup.inline(self.md, part.deck)}</p>'
            f'<div class="opener-rule"><span></span></div><ol class="opener-list">{"".join(items)}</ol></div>'
            f'<div class="opener-numeral">{part.numeral}</div>'
            f'<div class="opener-foot"><span>Redlamp User Manual</span><span>Part {part.number}</span></div></section>'
        )

    def _section(self, s: Section, pages: dict[str, int]) -> str:
        band = f"band-{s.part.band}" if s.part else "band-steel"
        page = s.page_name if s.part else "front"
        deck = f'<p class="deck">{markup.inline(self.md, s.deck)}</p>' if s.deck else ""
        sources = ""
        if s.sources:
            sources = '<p class="sources"><b>Sources:</b> ' + "; ".join(markup.inline(self.md, x) for x in s.sources) + "</p>"
        return (
            f'<article class="section {band}" id="{s.id}" style="page: {page}">'
            f'<header class="section-head"><div class="section-no">{s.number}</div>'
            f"<h1>{html.escape(s.title)}</h1>{deck}</header>"
            f'<div class="section-body">{self._xrefs(s.body, pages)}</div>{sources}</article>'
        )

    def _index(self) -> str:
        links = "".join(f'<a href="#{i}">{html.escape(i)}</a> ' for i in self.refs if i != "link-index")
        return f'<div class="link-index" id="link-index"><a href="#link-index">index</a> {links}</div>'

    # ---------------------------------------------------------------- the PDF's bookmarks

    def outline(self, pages: dict[str, int]) -> list[list]:
        toc = [[1, "Contents", pages["contents"]]]
        toc += [[1, s.title, pages[s.id]] for s in self.front if s.file]
        for part in self.parts:
            if not part.written:
                continue
            toc.append([1, f"Part {part.number}: {part.title}", pages[part.id]])
            for s in part.written:
                toc.append([2, f"{s.number} {s.title}", pages[s.id]])
                toc += [[3, text, pages[id_]] for level, id_, text in s.headings if level == 2]
        return toc
