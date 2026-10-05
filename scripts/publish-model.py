#!/usr/bin/env python3
"""Writes a converted model's files into its manifest, and publishes them as a GitHub prerelease.

    scripts/publish-model.py <manifest id> <folder>            # the manifest's files; nothing uploaded
    scripts/publish-model.py <manifest id> <folder> --upload   # and uploads them: ask the owner first (DEC-26)

A model goes up as the prerelease models-<id>-v<version> on pdcgomes/redlamp, which never becomes
the release marked Latest that the update feed, the site and Homebrew follow. Release assets can't
hold folders, so each '/' of a file's path is '__' in its asset's name (`ModelManifest.remote`), and
each file has to be under GitHub's 2 GiB. Until it's uploaded the manifest says `"published": false`
and `"cleared": false`; afterwards both follow its decision.
"""

import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFESTS = ROOT / "packages/RedlampMasking/Resources/Models"
REPOSITORY = "pdcgomes/redlamp"
LIMIT = 2 * 1024**3


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        while chunk := file.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    model_id, folder, upload = sys.argv[1], pathlib.Path(sys.argv[2]), "--upload" in sys.argv
    path = MANIFESTS / f"{model_id}.json"
    manifest = json.loads(path.read_text())
    tag = f"models-{model_id}-v{manifest['version']}"
    files = sorted(p for p in folder.rglob("*") if p.is_file() and not p.name.startswith("."))
    too_large = [p for p in files if p.stat().st_size >= LIMIT]
    if too_large:
        print("over GitHub's 2 GiB a file: " + ", ".join(str(p.relative_to(folder)) for p in too_large))
        return 1
    manifest["source"] = f"https://github.com/{REPOSITORY}/releases/download/{tag}/"
    manifest["files"] = [
        {"path": p.relative_to(folder).as_posix(), "bytes": p.stat().st_size, "sha256": sha256(p)} for p in files
    ]
    total = sum(f["bytes"] for f in manifest["files"])
    print(f"{model_id} v{manifest['version']}: {len(files)} files, {total / 1e9:.2f} GB")
    if upload:
        with tempfile.TemporaryDirectory(dir=folder.parent) as flat:
            assets = []
            for file in manifest["files"]:
                asset = pathlib.Path(flat) / file["path"].replace("/", "__")
                os.link(folder / file["path"], asset)
                assets.append(str(asset))
            exists = subprocess.run(["gh", "release", "view", tag, "--repo", REPOSITORY], capture_output=True).returncode == 0
            if not exists:
                notes = f"{manifest['name']}: {manifest['purpose']} Licence: {manifest['licenses']['weights']} (LICENSE.txt)."
                subprocess.run(
                    ["gh", "release", "create", tag, "--repo", REPOSITORY, "--prerelease", "--title",
                     f"{manifest['name']}, model version {manifest['version']}", "--notes", notes],
                    check=True,
                )
            subprocess.run(["gh", "release", "upload", tag, "--repo", REPOSITORY, "--clobber", *assets], check=True)
        manifest.pop("published", None)
        manifest["cleared"] = True
        print(f"uploaded to {manifest['source']}")
    else:
        manifest["published"] = False
        manifest["cleared"] = False
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
