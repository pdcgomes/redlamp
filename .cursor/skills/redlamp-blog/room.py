"""Where the blog stands, for the blog room (.cursor/skills/redlamp-blog/SKILL.md).

    python3 .cursor/skills/redlamp-blog/room.py status [--offline]
    python3 .cursor/skills/redlamp-blog/room.py thumbs [<canvas.tsx>]

status lists every post (web/content/blog/<slug>/index.md) and article (web/content/articles/<slug>/
index.md) on origin/main with its date, whether it's a draft and whether redlamp.app serves it (not with
--offline); each one's kit in docs/blog/social/<slug>/ and what's in it; the fact sheets in
docs/blog/facts/; and blog files that are only on another branch or uncommitted in a worktree. It reads
origin/main, which redlamp.app is built from, because the main checkout's main can be behind it.

thumbs writes every kit's thumb.jpg into the room, as data URIs between its THUMBS:BEGIN and THUMBS:END
lines, so the room can show each card. Renders aren't committed, so a kit's thumb comes from the main
checkout, or else from the first worktree that has rendered it. The room is the main checkout's, unless
a path is given.
"""
import base64
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MAIN = "origin/main"
SECTIONS = {"blog": "web/content/blog", "articles": "web/content/articles"}
KITS = ROOT / "docs/blog/social"
FACTS = ROOT / "docs/blog/facts"


def git(*args, cwd=ROOT):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True).stdout


def main_checkout():
    common = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir").strip())
    return common.parent


def worktrees():
    """Every checkout of the repository, the main one first."""
    return [Path(line.split(" ", 1)[1]) for line in git("worktree", "list", "--porcelain").splitlines()
            if line.startswith("worktree ")]


def front_matter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    fields = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        key, _, value = line.partition(":")
        fields[key.strip()] = value.split(" #")[0].strip()
    return fields


def served(section, slug):
    request = urllib.request.Request(f"https://redlamp.app/{section}/{slug}", headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return f"live ({response.status})"
    except urllib.error.HTTPError as error:
        return f"not served ({error.code})"
    except OSError as error:
        return f"unknown ({error.__class__.__name__})"


def status(offline):
    published = {}
    for section, folder in SECTIONS.items():
        slugs = published[section] = sorted(git("ls-tree", "--name-only", f"{MAIN}:{folder}").split())
        print(f"{'Posts' if section == 'blog' else 'Articles'} on {MAIN}:" + ("" if slugs else " none"))
        for slug in sorted(slugs, reverse=True,
                           key=lambda s: front_matter(git("show", f"{MAIN}:{folder}/{s}/index.md")).get("date", "")):
            fields = front_matter(git("show", f"{MAIN}:{folder}/{slug}/index.md"))
            state = "draft" if fields.get("draft") == "true" else ("not checked" if offline else served(section, slug))
            kit = KITS / slug
            files = " ".join(sorted(p.name for p in kit.iterdir())) if kit.is_dir() else "no kit"
            print(f"  {fields.get('date', '?')}  {slug}: {fields.get('title', '?')}")
            print(f"      {state}; kit: {files}")
    every = {slug for slugs in published.values() for slug in slugs}
    orphans = sorted(p.name for p in KITS.iterdir() if p.is_dir() and p.name not in every) if KITS.is_dir() else []
    if orphans:
        print(f"Kits for posts not on {MAIN}:", ", ".join(orphans))
    if FACTS.is_dir():
        print("Fact sheets:")
        for sheet in sorted(FACTS.glob("*.md")):
            tracked = "committed" if git("ls-files", str(sheet.relative_to(ROOT))).strip() else "not committed"
            print(f"  {sheet.relative_to(ROOT)} ({tracked})")
    print("Blog files elsewhere:")
    found = False
    for branch in git("for-each-ref", "--format=%(refname:short)", "refs/heads").split():
        for section, folder in SECTIONS.items():
            extra = set(git("ls-tree", "--name-only", f"{branch}:{folder}").split()) - set(published[section])
            for slug in sorted(extra):
                when = git("log", "-1", "--format=%ad %h", "--date=short", branch, "--", f"{folder}/{slug}").strip()
                print(f"  branch {branch}: {'' if section == 'blog' else 'articles/'}{slug} ({when})")
                found = True
    for tree in worktrees():
        changes = git("status", "--porcelain", "--untracked-files=all", "--", *SECTIONS.values(), cwd=tree).strip()
        if changes:
            print(f"  uncommitted in {tree}:")
            for change in changes.splitlines():
                print(f"    {change}")
            found = True
    if not found:
        print("  none")


def thumbs(canvas):
    found = {}
    for tree in worktrees():
        for thumb in sorted((tree / "docs/blog/social").glob("*/thumb.jpg")):
            found.setdefault(thumb.parent.name, thumb)
    entries = []
    for slug, thumb in sorted(found.items()):
        data = base64.b64encode(thumb.read_bytes()).decode()
        entries.append(f'  "{slug}": "data:image/jpeg;base64,{data}",')
    block = ["// THUMBS:BEGIN (room.py thumbs writes this block from docs/blog/social/*/thumb.jpg)",
             "const THUMBS: Record<string, string> = {", *entries, "};", "// THUMBS:END"]
    lines = canvas.read_text().splitlines()
    begin = next(i for i, line in enumerate(lines) if line.startswith("// THUMBS:BEGIN"))
    end = next(i for i, line in enumerate(lines) if line.startswith("// THUMBS:END"))
    canvas.write_text("\n".join(lines[:begin] + block + lines[end + 1:]) + "\n")
    print(f"{len(entries)} thumbnails written into {canvas}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "status":
        status("--offline" in sys.argv)
    elif command == "thumbs":
        project = str(main_checkout()).strip("/").replace("/", "-")
        default = Path.home() / ".cursor/projects" / project / "canvases/blog-room.canvas.tsx"
        thumbs(Path(sys.argv[2]) if len(sys.argv) > 2 else default)
    else:
        sys.exit(__doc__)
