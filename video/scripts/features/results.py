"""
The real results in the feature videos: Redlamp's own renders of the owner's photos, from his edit in
the .redlamp sidecar beside each raw (docs/recipes/sidecar-format.md), made with the redlamp CLI. A
render is kept in public/features/<episode>/results/ under a name made from everything that went into
it (the photo, the edit, the settings, the size and the CLI), so it is made again only when one of
them changes.

The CLI is $REDLAMP_CLI, or else build/cli/redlamp in this checkout: a build of main's redlamp scheme.
"""

import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

from features import world as w

CLI = Path(os.environ.get("REDLAMP_CLI", w.REPO / "build/cli/redlamp"))


def sidecar(raw):
    """The path of the edit saved beside `raw` (a package, or a single file from before format 3), or
    None when there isn't one."""
    path = Path(f"{raw}.redlamp")
    return path if path.exists() else None


def recipe_of(edit):
    """The recipe in a sidecar, or `edit` itself when it's already a recipe (a dict)."""
    if isinstance(edit, dict):
        return edit
    path = Path(edit) / "edit.json" if Path(edit).is_dir() else Path(edit)
    return json.loads(path.read_text())["recipe"]


def geometry(edit):
    """The edit's crop, straightening, turns and Transform alone, at its process version: the photo as
    Redlamp opens it, framed as the edit frames it."""
    recipe = recipe_of(edit)
    values = {k: v for k, v in recipe.get("values", {}).items() if k == "crop.angle" or k.startswith("transform.")}
    out = {"version": recipe.get("version", 3), "processVersion": recipe.get("processVersion", 1), "values": values}
    for key in ("crop", "orientation"):
        if key in recipe:
            out[key] = recipe[key]
    return out


def _fingerprint(edit):
    if edit is None:
        return None
    if isinstance(edit, dict):
        return json.dumps(edit, sort_keys=True)
    path = Path(edit)
    files = sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path]
    return [(str(p.relative_to(path)) if path.is_dir() else p.name, hashlib.sha256(p.read_bytes()).hexdigest()) for p in files]


def render(raw, folder, name, *, edit=None, sets=(), size=2048):
    """Redlamp's render of `raw`, `size` pixels on its long edge, from `edit` (a sidecar's path or a
    recipe) with `sets`, (parameter, value) pairs, on top. Returns it as an image."""
    raw, folder = Path(raw), Path(folder)
    key = json.dumps([raw.name, raw.stat().st_size, raw.stat().st_mtime_ns, _fingerprint(edit), list(map(list, sets)),
                      size, CLI.stat().st_mtime_ns])
    path = folder / f"{name}-{hashlib.sha256(key.encode()).hexdigest()[:12]}.png"
    if not path.exists():
        folder.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as tmp:
            cmd = [str(CLI), "render", str(raw), "-o", str(path), "--size", str(size)]
            if isinstance(edit, dict):
                recipe = Path(tmp) / "recipe.json"
                recipe.write_text(json.dumps(edit))
                cmd += ["--recipe", str(recipe)]
            elif edit is not None:
                cmd += ["--recipe", str(edit)]
            for parameter, value in sets:
                cmd += ["--set", f"{parameter}={value}"]
            done = subprocess.run(cmd, capture_output=True, text=True)
            if done.returncode != 0:
                raise SystemExit(f"redlamp render failed for {name}: {done.stderr.strip() or done.stdout.strip()}")
        for old in folder.glob(f"{name}-*.png"):
            if old != path:
                old.unlink()
    return Image.open(path).convert("RGB")
