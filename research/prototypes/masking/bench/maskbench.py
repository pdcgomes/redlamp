"""The mask bench (MSK-38): Subject, Sky and Background masks from Redlamp, candidate models and
Lightroom desktop side by side on the CC0 pool, scored, and judged blind in a review page.

    mise run maskbench -- build              the Release CLI the bench runs, from the working tree
    mise run maskbench -- photos             each photo at the bench's size, as the review page shows it
    mise run maskbench -- run --contenders redlamp[,…] [--photos all|quick|cell:<cell>|<ids>]
                                [--kinds subject,sky,background] [--processes 2] [--run <name>]
    mise run maskbench -- score --candidate <source> --reference <source> [--kinds …]
    mise run maskbench -- review [--a redlamp --b lightroom] [--port 8765]
    mise run maskbench -- lightroom prepare|calibrate|decode|selftest
    mise run maskbench -- check [--no-build]  the regression check before a mask change ships
    mise run maskbench -- accept <source>     the run `check` compares against, per contender
    mise run maskbench -- pool search|add|drop  more CC0 photos, in the cells marked `added` (pool.py)
    mise run maskbench -- contenders          the contenders and their runs
    mise run maskbench -- prune               delete runs that are neither accepted nor a contender's latest

A source is `<contender>` (its latest run), `<contender>@<run>`, `lightroom` or `lightroom@<version>`.
Photos and masks live in build/mask-bench (never committed); the contenders, the quick subset, the
accepted runs, the verdicts and the references' index live in research/mask-eval.
"""

import argparse
import datetime
import json
import shutil
import subprocess
import sys

import common as c
import scoring

CHECK_MOVED = {"iou": 0.98, "boundaryF": 0.95, "regionDisagreement": 0.002}
TEXTURE_LIMIT = 16384


def build(_args=None):
    print(f"==> Building the redlamp CLI (Release) into {c.DERIVED}")
    subprocess.run(["xcodebuild", "build", "-workspace", "Redlamp.xcworkspace", "-scheme", "redlamp",
                    "-configuration", "Release", "-destination", "platform=macOS,arch=arm64",
                    "-derivedDataPath", str(c.DERIVED), "-quiet"], cwd=c.ROOT, check=True)


def photos(args):
    entries = c.select(args.photos)
    for number, entry in enumerate(entries, 1):
        if not entry["path"].exists():
            print(f"    missing {entry['path']} (mise run maskeval, mise run lookdev)", file=sys.stderr)
            continue
        c.bench_jpeg(entry)
        if number % 20 == 0 or number == len(entries):
            print(f"    {number}/{len(entries)} photos at {c.SIZE} px in {c.PHOTOS}")


def run(args):
    import contenders

    if not c.CLI.exists():
        build()
    entries = [e for e in c.select(args.photos) if e["path"].exists()]
    # Redlamp aborts on a photo wider or taller than Metal's largest texture (16,384 px).
    too_large = [e["id"] for e in entries if e.get("longEdge", 0) > TEXTURE_LIMIT]
    if too_large:
        print(f"    left out, over {TEXTURE_LIMIT} px on the long side, which Redlamp can't open: {', '.join(too_large)}")
        entries = [e for e in entries if e["id"] not in too_large]
    for entry in entries:
        c.bench_jpeg(entry)
    name = args.run or datetime.datetime.now().strftime("%Y-%m-%d-%H%M")
    registry = c.contenders()
    for contender_id in args.contenders.split(","):
        spec = registry[contender_id]
        kinds = [k for k in args.kinds.split(",") if k in spec["kinds"]]
        print(f"==> {contender_id}: {len(entries)} photos, {', '.join(kinds)}, run {name}")
        if spec["runner"] == "redlamp":
            contenders.run_redlamp(name, spec, entries, kinds, args.processes, missing_only=args.missing)
        elif spec["runner"] == "python":
            contenders.run_python(name, spec, entries, kinds, args.processes)
        else:
            sys.exit(f"{contender_id} isn't run by the bench: decode Lightroom's exports (maskbench lightroom decode)")


def score_pair(candidate, reference, kinds, entries=None):
    """Metrics of `candidate` against `reference` for every photo and kind both have."""
    a_folder, a_name = c.resolve(candidate)
    b_folder, b_name = c.resolve(reference)
    rows = []
    for entry in entries or c.pool():
        for kind in kinds:
            a = c.mask_path(a_folder, kind, entry["id"])
            b = c.mask_path(b_folder, kind, entry["id"])
            if not (a.exists() and b.exists()):
                continue
            size = c.size_of(entry)
            unknown = c.unknown_path(b_folder, kind, entry["id"])
            rows.append({
                "photo": entry["id"], "cell": entry["cell"], "kind": kind,
                "metrics": scoring.metrics(c.read_mask(a, size), c.read_mask(b, size),
                                           c.read_mask(unknown, size) >= 0.5 if unknown.exists() else None),
            })
    return a_name, b_name, rows


def score(args):
    a_name, b_name, rows = score_pair(args.candidate, args.reference, args.kinds.split(","))
    if not rows:
        sys.exit("no photo has masks from both")
    summary = scoring.summary(rows)
    c.SCORES.mkdir(parents=True, exist_ok=True)
    path = c.SCORES / f"{a_name}__vs__{b_name}.json".replace("/", "-")
    path.write_text(json.dumps({"candidate": a_name, "reference": b_name, "made": c.now(),
                                "summary": summary, "rows": rows}, indent=1) + "\n")
    print(f"==> {a_name} against {b_name}")
    for kind, s in summary.items():
        print(f"    {kind:10} {s['photos']:4} photos  IoU {s['medianIoU']:.3f}  boundary F {s['medianBoundaryF']:.3f}  "
              f"region over 1% of the frame on {s['regionOver1pc']:.0%}, over 5% on {s['regionOver5pc']:.0%}  "
              f"edge {s['meanEdgeDisagreement']:.2%}")
    worst = sorted(rows, key=lambda r: -scoring.disagreement(r["metrics"]))[:args.worst]
    if worst:
        print("    largest disagreements:")
        for r in worst:
            m = r["metrics"]
            print(f"      {r['kind']:10} {r['photo']:32} region {m['regionDisagreement']:.1%}  "
                  f"missed {m['missed']:.0%} extra {m['extra']:.0%}  IoU {m['iou']:.3f}")
    print(f"    {path.relative_to(c.ROOT)}")


def accepted():
    return json.loads(c.ACCEPTED.read_text()) if c.ACCEPTED.exists() else {}


def accept(args):
    _, name = c.resolve(args.source)
    contender, _, run_name = name.partition("@")
    data = accepted()
    data[contender] = run_name
    c.ACCEPTED.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")
    print(f"==> {contender}: accepted run {run_name} ({c.ACCEPTED.relative_to(c.ROOT)})")


def references():
    """The accepted reference of each photo and kind: the latest line for it in references.jsonl."""
    out = {}
    if c.REFERENCES.exists():
        for line in c.REFERENCES.read_text().splitlines():
            if line.strip():
                item = json.loads(line)
                out[(item["photo"], item["kind"])] = item
    return out


def check(args):
    """Today's working tree against the accepted Redlamp run on the quick subset: which masks moved,
    and whether they moved towards the accepted references or away from them."""
    if not args.no_build:
        build()
    baseline = accepted().get("redlamp")
    if not baseline:
        sys.exit("no accepted Redlamp run yet: maskbench accept redlamp@<run>")
    entries = [e for e in c.select("quick") if e["path"].exists()]
    name = datetime.datetime.now().strftime("%Y-%m-%d-%H%M") + "-check"
    args.contenders, args.photos, args.run = "redlamp", "quick", name
    run(args)
    kinds = args.kinds.split(",")
    _, _, moved_rows = score_pair(f"redlamp@{name}", f"redlamp@{baseline}", kinds, entries)
    refs = references()
    moved = []
    for row in moved_rows:
        m = row["metrics"]
        if m["iou"] >= CHECK_MOVED["iou"] and m["boundaryF"] >= CHECK_MOVED["boundaryF"] \
                and m["regionDisagreement"] <= CHECK_MOVED["regionDisagreement"]:
            continue
        item = {"photo": row["photo"], "kind": row["kind"], "iou": m["iou"], "region": m["regionDisagreement"]}
        ref = refs.get((row["photo"], row["kind"]))
        path = c.REFS / row["kind"] / f"{row['photo']}.png"
        if ref and path.exists():
            entry = c.photo(row["photo"])
            size = c.size_of(entry)
            truth = c.read_mask(path, size)
            now_ = c.read_mask(c.mask_path(c.RUNS / name / "redlamp", row["kind"], row["photo"]), size)
            then = c.read_mask(c.mask_path(c.RUNS / baseline / "redlamp", row["kind"], row["photo"]), size)
            item["referenceIoU"] = {"before": scoring.metrics(then, truth)["iou"], "after": scoring.metrics(now_, truth)["iou"]}
        moved.append(item)
    report = {"run": name, "against": baseline, "made": c.now(), "photos": len(entries), "moved": moved}
    (c.WORK / "check.json").write_text(json.dumps(report, indent=1) + "\n")
    worse = [m for m in moved if "referenceIoU" in m and m["referenceIoU"]["after"] < m["referenceIoU"]["before"] - 0.01]
    print(f"==> {len(moved)} of {len(moved_rows)} masks moved against {baseline}; "
          f"{len(worse)} moved away from their reference")
    for m in moved[:30]:
        ref = m.get("referenceIoU")
        towards = f"  reference IoU {ref['before']:.3f} → {ref['after']:.3f}" if ref else ""
        print(f"    {m['kind']:10} {m['photo']:32} IoU with before {m['iou']:.3f}{towards}")
    if moved:
        print(f"    review them: mise run maskbench -- review --a redlamp@{name} --b redlamp@{baseline} --queue changed")
    sys.exit(1 if worse else 0)


def fetch_model(args):
    """A Hugging Face-hosted model's files into Redlamp's model store, through Python, whose
    downloads reach the network from the agents' sandbox where the app's own time out; each file is
    checked against its manifest's size and SHA-256."""
    import hashlib
    import os
    import re

    from huggingface_hub import hf_hub_download

    manifest = json.loads((c.ROOT / "packages/RedlampMasking/Resources/Models" / f"{args.model}.json").read_text())
    found = re.match(r"https://huggingface.co/([^/]+/[^/]+)/resolve/([^/]+)/", manifest["source"])
    if not found:
        sys.exit(f"{args.model} isn't served from Hugging Face ({manifest['source']})")
    repo, revision = found.groups()
    target = c.pathlib.Path.home() / "Library/Application Support/Redlamp/Models" / manifest["id"] / str(manifest["version"])
    os.environ.setdefault("HF_HUB_CACHE", "/Volumes/SSD/redlamp-tmp/mask-bench/hf-hub")
    for file in manifest["files"]:
        path = c.pathlib.Path(hf_hub_download(repo, file["path"], revision=revision))
        if path.stat().st_size != file["bytes"] or hashlib.sha256(path.read_bytes()).hexdigest() != file["sha256"]:
            sys.exit(f"{file['path']} doesn't match the manifest")
        destination = target / file["path"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
    print(f"==> {manifest['name']}: {len(manifest['files'])} files in {target}")


def list_contenders(_args):
    keep = accepted()
    for contender_id, spec in c.contenders().items():
        runs = c.lightroom_versions() if spec["runner"] == "lightroom" else c.runs_of(contender_id)
        shown = ", ".join(f"{r}{' (accepted)' if keep.get(contender_id) == r else ''}" for r in runs[-4:]) or "none yet"
        print(f"{contender_id:28} {spec['licence']:10} {','.join(spec['kinds']):26} runs: {shown}")


def prune(_args):
    keep = set(accepted().values())
    for contender_id in c.contenders():
        runs = c.runs_of(contender_id)
        if runs:
            keep.add(runs[-1])
    if not c.RUNS.exists():
        return
    for folder in sorted(c.RUNS.iterdir()):
        if folder.is_dir() and folder.name not in keep:
            shutil.rmtree(folder)
            print(f"    removed {folder.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build").set_defaults(func=build)
    p = sub.add_parser("photos")
    p.add_argument("--photos", default="all")
    p.set_defaults(func=photos)
    for name, func in (("run", run), ("check", check)):
        p = sub.add_parser(name)
        p.add_argument("--contenders", default="redlamp")
        p.add_argument("--photos", default="all")
        p.add_argument("--kinds", default=",".join(c.KINDS))
        p.add_argument("--processes", type=int, default=2)
        p.add_argument("--run")
        p.add_argument("--missing", action="store_true", help="make only the masks the run doesn't have yet")
        if name == "check":
            p.add_argument("--no-build", action="store_true")
        p.set_defaults(func=func)
    p = sub.add_parser("score")
    p.add_argument("--candidate", required=True)
    p.add_argument("--reference", required=True)
    p.add_argument("--kinds", default=",".join(c.KINDS))
    p.add_argument("--worst", type=int, default=12)
    p.set_defaults(func=score)
    p = sub.add_parser("review")
    p.add_argument("--a", default="redlamp")
    p.add_argument("--b", default="lightroom")
    p.add_argument("--queue", default="disagreement")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--no-open", action="store_true", help="don't open the page in the browser")
    p.set_defaults(func=lambda a: __import__("review").serve(a))
    p = sub.add_parser("lightroom")
    p.add_argument("action", choices=["prepare", "calibrate", "decode", "selftest"])
    p.add_argument("--inbox", default=str(c.LIGHTROOM / "inbox"))
    p.add_argument("--model", choices=["auto", "blend", "scale"], default="auto")
    p.set_defaults(func=lambda a: __import__("lightroom").main(a))
    p = sub.add_parser("pool")
    p.add_argument("action", choices=["search", "add", "drop"])
    p.add_argument("files", nargs="*")
    p.add_argument("--cells")
    p.set_defaults(func=lambda a: __import__("pool").main(a))
    p = sub.add_parser("accept")
    p.add_argument("source")
    p.set_defaults(func=accept)
    p = sub.add_parser("fetch-model")
    p.add_argument("model")
    p.set_defaults(func=fetch_model)
    sub.add_parser("contenders").set_defaults(func=list_contenders)
    sub.add_parser("prune").set_defaults(func=prune)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
