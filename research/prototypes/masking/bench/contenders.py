"""Running contenders (MSK-38): Redlamp through `redlamp mask --batch`, and Python models whose
regions are given Redlamp's own edges, as Refine Edges solves them.

A run keeps each contender's masks at the bench's size in `build/mask-bench/runs/<run>/<contender>/
<kind>/<photo>.png`, and `run.json` records, per contender, the commit, the CLI's environment, and
for each mask the seconds it took and the provider that made it (or its error).
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time

import numpy as np

import common as c


def record(run, contender, entry):
    path = c.RUNS / run / "run.json"
    data = json.loads(path.read_text()) if path.exists() else {"run": run, "created": c.now(), "contenders": {}}
    data["contenders"][contender] = entry
    path.write_text(json.dumps(data, indent=1) + "\n")


def batch(jobs, env, label):
    """Runs `jobs` through one `redlamp mask --batch` process; returns its JSON lines."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", dir=c.WORK, delete=False) as file:
        json.dump(jobs, file)
        path = file.name
    results = []
    try:
        process = subprocess.Popen([str(c.CLI), "mask", "--batch", path], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env={**os.environ, **env})
        started = time.time()
        for line in process.stdout:
            # Core ML can print a warning without a newline just before a job's line.
            start = line.find('{"')
            if start < 0:
                continue
            results.append(json.loads(line[start:]))
            done = len(results)
            if done % 10 == 0 or done == len(jobs):
                rate = (time.time() - started) / done
                print(f"    {label}: {done}/{len(jobs)} masks, {rate:.1f} s each, "
                      f"{rate * (len(jobs) - done) / 60:.0f} min left", flush=True)
        stderr = process.stderr.read()
        if process.wait() != 0:
            print(f"    {label}: the CLI stopped ({process.returncode}): {stderr.strip()[-400:]}", file=sys.stderr)
    finally:
        os.unlink(path)
    return results


def run_redlamp(run, contender, photos, kinds, processes=1, regions=None, missing_only=False):
    """Redlamp's masks for `photos`, in `processes` processes, each taking whole photos so that a
    photo's masks share its analysis render. `regions`: a folder of region PNGs (`<kind>/<photo>.png`)
    to start from instead, each edge then solved again as Refine Edges does. A mask that finds
    nothing (no subject, no sky) is kept as an empty one, as it would leave the photo unedited.
    `missing_only` makes only the masks the run doesn't have yet."""
    spec = contender if isinstance(contender, dict) else c.contenders()[contender]
    out = c.RUNS / run / spec["id"]
    jobs = []
    for entry in photos:
        for kind in kinds:
            if missing_only and (out / kind / f"{entry['id']}.png").exists():
                continue
            job = {"image": str(entry["path"]), "kind": kind, "output": str(out / kind / f"{entry['id']}.native.png")}
            if regions is not None:
                region = regions / kind / f"{entry['id']}.png"
                if not region.exists():
                    continue
                job.update({"from": str(region), "refineEdges": True})
            jobs.append((entry, kind, job))
    for kind in kinds:
        (out / kind).mkdir(parents=True, exist_ok=True)
    started = c.now()
    if spec.get("download") and photos:
        # A model another kind uses (Objects' Segment Anything, for Sky) is downloaded before the
        # batches start, or their first masks would be made without it.
        scratch = out / f"_download.{spec['download']}.png"
        lines = batch([{"image": str(photos[0]["path"]), "kind": spec["download"], "points": [[0.5, 0.5]],
                        "output": str(scratch)}], spec.get("env", {}), f"{spec['id']} download")
        for leftover in out.glob("_download.*"):
            leftover.unlink()
        if not lines or "error" in lines[0]:
            # Without the model the masks would quietly be made another way.
            raise SystemExit(f"{spec['id']}: its model isn't on this Mac ({lines[0]['error'] if lines else 'no answer'}); "
                             f"maskbench fetch-model <id> puts it there")
    shares = [[] for _ in range(max(1, processes))]
    for index, entry in enumerate(photos):
        shares[index % len(shares)].extend(job for job in jobs if job[0] is entry)
    results = {}

    def work(share, number):
        for line in batch([job for _, _, job in share], spec.get("env", {}), f"{spec['id']} #{number + 1}"):
            results[line["output"]] = line

    threads = [threading.Thread(target=work, args=(share, n)) for n, share in enumerate(shares) if share]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    previous = {}
    path = c.RUNS / run / "run.json"
    if missing_only and path.exists():
        previous = json.loads(path.read_text())["contenders"].get(spec["id"], {}).get("masks", {})
    masks = {kind: dict(previous.get(kind, {})) for kind in kinds}
    for entry, kind, job in jobs:
        line = results.get(job["output"], {"error": "no result"})
        native = pathlib.Path(job["output"])
        item = {"seconds": round(line.get("seconds", 0), 2)}
        if "error" in line and " was found" in line["error"]:
            item["nothingFound"] = True
            size = c.size_of(entry)
            c.write_mask(out / kind / f"{entry['id']}.png", np.zeros((size[1], size[0]), np.float32))
        elif "error" in line:
            item["error"] = line["error"]
        else:
            item["provider"] = line["masks"][0]["provider"] if line.get("masks") else None
            try:
                c.write_mask(out / kind / f"{entry['id']}.png", c.read_mask(native, c.size_of(entry)))
            except (ValueError, FileNotFoundError) as error:
                item["error"] = str(error)
        for leftover in native.parent.glob(f"{native.stem}*.png"):
            leftover.unlink()
        masks[kind][entry["id"]] = item
    record(run, spec["id"], {
        "label": spec.get("label", spec["id"]),
        "runner": "redlamp",
        "commit": c.commit(),
        "cli": str(c.CLI),
        "env": spec.get("env", {}),
        "regions": str(regions) if regions is not None else None,
        "started": started,
        "finished": c.now(),
        "masks": masks,
    })
    items = [item for kind_items in masks.values() for item in kind_items.values()]
    failed = sum("error" in item for item in items)
    nothing = sum(item.get("nothingFound", False) for item in items)
    print(f"==> {spec['id']}: {len(items) - failed} masks ({nothing} found nothing, kept empty), "
          f"{failed} failed, in {out}")


def run_python(run, spec, photos, kinds, processes=1):
    """A Python model's regions for `photos`, then Redlamp's edges on them when `edges` is redlamp."""
    import candidates

    model = candidates.load(spec)
    out = c.RUNS / run / spec["id"]
    regions = out / "_regions"
    started = c.now()
    timings = {kind: {} for kind in kinds}
    for number, entry in enumerate(photos, 1):
        image = c.bench_jpeg(entry)
        began = time.time()
        try:
            maps = model.predict(image, kinds)
        except Exception as error:  # noqa: BLE001 - recorded with the run
            for kind in kinds:
                timings[kind][entry["id"]] = {"error": f"{type(error).__name__}: {error}"}
            continue
        seconds = round(time.time() - began, 2)
        for kind in kinds:
            if kind in maps:
                c.write_mask(regions / kind / f"{entry['id']}.png", maps[kind])
                timings[kind][entry["id"]] = {"seconds": seconds}
        if number % 10 == 0 or number == len(photos):
            print(f"    {spec['id']}: {number}/{len(photos)} photos", flush=True)
    if spec.get("edges") == "redlamp":
        # Redlamp solves Background as the Subject it is the inverse of, so a model's Background is
        # its solved Subject inverted rather than solved again.
        derived = "subject" in kinds and "background" in kinds and spec.get("model") in ("dichotomous", "ben2")
        run_redlamp(run, spec, photos, [k for k in kinds if not (derived and k == "background")], processes,
                    regions=regions)
        data = json.loads((c.RUNS / run / "run.json").read_text())
        entry = data["contenders"][spec["id"]]
        if derived:
            entry["masks"]["background"] = {}
            for photo in photos:
                subject = c.mask_path(out, "subject", photo["id"])
                if subject.exists():
                    c.write_mask(c.mask_path(out, "background", photo["id"]), 1 - c.read_mask(subject, c.size_of(photo)))
                    entry["masks"]["background"][photo["id"]] = {"derived": "subject inverted"}
        entry.update({"runner": "python", "model": spec.get("model"), "repo": spec.get("repo"), "regionTimes": timings})
        record(run, spec["id"], entry)
        return
    for kind in kinds:
        for path in (regions / kind).glob("*.png"):
            target = out / kind / path.name
            target.parent.mkdir(parents=True, exist_ok=True)
            path.replace(target)
    record(run, spec["id"], {
        "label": spec.get("label", spec["id"]), "runner": "python", "model": spec.get("model"),
        "repo": spec.get("repo"), "commit": c.commit(), "started": started, "finished": c.now(), "masks": timings,
    })
