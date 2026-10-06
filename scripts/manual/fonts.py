"""The manual's fonts: Inter 4.1 for text and Inter Display for headings, as the brand sets for
documents (docs/brand/README.md), and JetBrains Mono 2.304 for code and labels. All three are
under the SIL Open Font License. They are downloaded once from their GitHub releases, checked
against the hashes below, and unpacked into build/manual/fonts with their licences.

Only static faces are used: Chrome embeds a variable font in a PDF as Type 3 glyphs, which
viewers draw without hinting and can't copy text from as reliably.
"""

import hashlib
import urllib.request
import zipfile
from pathlib import Path

RELEASES = {
    "inter": (
        "https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip",
        "9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e",
        {"LICENSE.txt": "Inter-LICENSE.txt"},
    ),
    "jetbrains": (
        "https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip",
        "6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf",
        {"OFL.txt": "JetBrainsMono-OFL.txt"},
    ),
}

# family, weight, style, file, release, path in the release's archive
FACES = [
    ("Inter", 400, "normal", "Inter-Regular.woff2", "inter", "web/Inter-Regular.woff2"),
    ("Inter", 400, "italic", "Inter-Italic.woff2", "inter", "web/Inter-Italic.woff2"),
    ("Inter", 500, "normal", "Inter-Medium.woff2", "inter", "web/Inter-Medium.woff2"),
    ("Inter", 500, "italic", "Inter-MediumItalic.woff2", "inter", "web/Inter-MediumItalic.woff2"),
    ("Inter", 600, "normal", "Inter-SemiBold.woff2", "inter", "web/Inter-SemiBold.woff2"),
    ("Inter", 700, "normal", "Inter-Bold.woff2", "inter", "web/Inter-Bold.woff2"),
    ("Inter Display", 300, "italic", "InterDisplay-LightItalic.woff2", "inter", "web/InterDisplay-LightItalic.woff2"),
    ("Inter Display", 400, "normal", "InterDisplay-Regular.woff2", "inter", "web/InterDisplay-Regular.woff2"),
    ("Inter Display", 400, "italic", "InterDisplay-Italic.woff2", "inter", "web/InterDisplay-Italic.woff2"),
    ("Inter Display", 500, "normal", "InterDisplay-Medium.woff2", "inter", "web/InterDisplay-Medium.woff2"),
    ("Inter Display", 600, "normal", "InterDisplay-SemiBold.woff2", "inter", "web/InterDisplay-SemiBold.woff2"),
    ("Inter Display", 700, "normal", "InterDisplay-Bold.woff2", "inter", "web/InterDisplay-Bold.woff2"),
    ("JetBrains Mono", 400, "normal", "JetBrainsMono-Regular.woff2", "jetbrains", "fonts/webfonts/JetBrainsMono-Regular.woff2"),
    ("JetBrains Mono", 500, "normal", "JetBrainsMono-Medium.woff2", "jetbrains", "fonts/webfonts/JetBrainsMono-Medium.woff2"),
    ("JetBrains Mono", 700, "normal", "JetBrainsMono-Bold.woff2", "jetbrains", "fonts/webfonts/JetBrainsMono-Bold.woff2"),
]

EMBEDDED = ("Inter-", "InterDisplay-", "JetBrainsMono-")


def ensure(fonts: Path, cache: Path) -> None:
    """Downloads and unpacks whatever is missing from `fonts`."""
    fonts.mkdir(parents=True, exist_ok=True)
    for release, (url, sha256, licences) in RELEASES.items():
        wanted = {f[3]: f[5] for f in FACES if f[4] == release} | {v: k for k, v in licences.items()}
        missing = {name: member for name, member in wanted.items() if not (fonts / name).exists()}
        if not missing:
            continue
        archive = cache / url.rsplit("/", 1)[1]
        if not archive.exists():
            cache.mkdir(parents=True, exist_ok=True)
            print(f"Downloading {url}")
            with urllib.request.urlopen(url) as response:
                archive.write_bytes(response.read())
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != sha256:
            archive.unlink()
            raise SystemExit(f"error: {archive.name} has SHA-256 {digest}, not {sha256}; deleted it, try again")
        with zipfile.ZipFile(archive) as zf:
            for name, member in missing.items():
                (fonts / name).write_bytes(zf.read(member))


def css() -> str:
    return "\n".join(
        f'@font-face {{ font-family: "{family}"; font-weight: {weight}; font-style: {style}; '
        f'src: url("fonts/{file}") format("woff2"); }}'
        for family, weight, style, file, _, _ in FACES
    )
