#!/usr/bin/env python3
"""The benchmark sets AI Denoise and removal are measured on (INF-14): list them and fetch their files.

    research/benchmarks/benchmarks.py list [--set denoise] [--private]
    research/benchmarks/benchmarks.py fetch [--set removal] [--synthetic] [--private] [--pause 2]

Each set is a manifest beside this script (denoise.json, removal.json, glass.json); the owner's own
photos may be listed in a private manifest of the same name in
~/Library/Application Support/Redlamp/Benchmarks/. Downloads go to build/benchmarks/<set>/, checked
against their SHA-256, one at a time with a pause between; fixtures are used where the repository's
fixture tasks put them; synthetic cases are made by their set's generator. README.md has the format.
Other scripts import `cases` and `resolve` to find a case's file.
"""

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build" / "benchmarks"
PRIVATE = pathlib.Path.home() / "Library" / "Application Support" / "Redlamp" / "Benchmarks"
SETS = ("denoise", "removal", "glass")
PUBLIC_LICENCES = {"CC0-1.0", "synthetic", "CC-BY-4.0", "CC-BY-SA-4.0"}
SOURCES = ("url", "fixture", "generator", "path")
SCORES = {"truth", "pair", "picks"}


def manifest_path(set_name, private=False):
    return (PRIVATE if private else HERE) / f"{set_name}.json"


def manifest(set_name, private=False):
    path = manifest_path(set_name, private)
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    problems = validate(data, set_name, private)
    if problems:
        raise SystemExit(f"{path}:\n  " + "\n  ".join(problems))
    return data


def validate(data, set_name, private):
    problems = []
    if data.get("set") != set_name:
        problems.append(f"set is {data.get('set')!r}, expected {set_name!r}")
    ids, files = set(), set()
    for index, case in enumerate(data.get("cases", [])):
        where = case.get("id", f"case {index}")
        for field in ("id", "group", "source", "licence", "score"):
            if field not in case:
                problems.append(f"{where}: no {field}")
        source = case.get("source", {})
        kinds = [kind for kind in SOURCES if kind in source]
        if len(kinds) != 1:
            problems.append(f"{where}: source needs exactly one of {', '.join(SOURCES)}")
        elif kinds[0] == "path" and not private:
            problems.append(f"{where}: path sources belong in the private manifest")
        elif kinds[0] in ("url", "fixture") and "sha256" not in source:
            problems.append(f"{where}: no sha256")
        if kinds and kinds[0] in ("url", "generator") and "file" not in case:
            problems.append(f"{where}: no file")
        if not private and case.get("licence") not in PUBLIC_LICENCES:
            problems.append(f"{where}: licence {case.get('licence')!r}; only {', '.join(sorted(PUBLIC_LICENCES))} here")
        if case.get("licence", "").startswith("CC-BY") and not case.get("credit"):
            problems.append(f"{where}: a CC BY licence needs its credit")
        if case.get("score") not in SCORES:
            problems.append(f"{where}: score {case.get('score')!r}, expected one of {', '.join(sorted(SCORES))}")
        if case.get("id") in ids:
            problems.append(f"{where}: id used twice")
        ids.add(case.get("id"))
        if case.get("file"):
            if case["file"] in files:
                problems.append(f"{where}: file {case['file']} used twice")
            files.add(case["file"])
    return problems


def cases(set_name, private=False):
    data = manifest(set_name, private)
    return data["cases"] if data else []


def resolve(set_name, case):
    """Where a case's file is, or will be once fetched."""
    source = case["source"]
    if "path" in source:
        return pathlib.Path(source["path"]).expanduser()
    if "fixture" in source:
        return ROOT / source["fixture"]
    return BUILD / set_name / case["file"]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def state(set_name, case):
    path = resolve(set_name, case)
    if not path.exists():
        return "missing"
    expected = case["source"].get("sha256")
    if expected and sha256(path) != expected:
        return "hash mismatch"
    return "ready"


def fetch_case(set_name, case, synthetic, pause):
    source = case["source"]
    current = state(set_name, case)
    if current == "ready":
        return current
    if "url" in source:
        target = resolve(set_name, case)
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(target.name + ".part")
        request = urllib.request.Request(source["url"], headers={"User-Agent": "redlamp-benchmarks"})
        with urllib.request.urlopen(request, timeout=120) as response, open(partial, "wb") as handle:
            while block := response.read(1 << 20):
                handle.write(block)
        if sha256(partial) != source["sha256"]:
            partial.unlink()
            return "hash mismatch after download"
        partial.rename(target)
        time.sleep(pause)
        return "downloaded"
    if "generator" in source and synthetic:
        out = BUILD / set_name
        out.mkdir(parents=True, exist_ok=True)
        command = [sys.executable, str(ROOT / source["generator"]), *source.get("args", [])]
        subprocess.run(command, cwd=ROOT, check=True, env={**os.environ, "BENCHMARK_OUT": str(out)})
        return state(set_name, case)
    if "fixture" in source:
        return f"{current}: fetch it with the repository's fixture tasks"
    return current


def selected(args):
    names = [args.set] if args.set else SETS
    for name in names:
        for private in (False, True) if args.private else (False,):
            for case in cases(name, private):
                yield name, private, case


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("list", "fetch"))
    parser.add_argument("--set", choices=SETS)
    parser.add_argument("--private", action="store_true", help="include the owner's private manifests")
    parser.add_argument("--synthetic", action="store_true", help="also make the synthetic cases")
    parser.add_argument("--pause", type=float, default=2.0, help="seconds between downloads")
    args = parser.parse_args()

    failed = 0
    for name, private, case in selected(args):
        label = f"{name}{' (private)' if private else ''}/{case['id']}"
        if args.command == "list":
            print(f"{state(name, case):14} {label:48} {case['group']:12} {case['score']:6} {case['licence']}")
            continue
        result = fetch_case(name, case, args.synthetic, args.pause)
        failed += result not in ("ready", "downloaded")
        print(f"{result:14} {label}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
