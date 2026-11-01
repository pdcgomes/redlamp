# Benchmarks for AI Denoise and removal (INF-14)

The fixed sets of photos that AI Denoise (DN-17, DN-09) and Generative Remove (RM-20, RM-21, RM-22) are measured on, beside Lightroom's results on the same photos, so that "as good as Lightroom" is a measurement rather than an impression. Tracker: INF-14, [#522](https://github.com/pdcgomes/redlamp/issues/522).

| Set | Manifest | Groups | Measured by |
| --- | --- | --- | --- |
| Denoise | `denoise.json` | Synthetic scenes with exact truth; RawNIND pairs the models didn't train on; real raws at ISO 3200 to 51200, Bayer and X-Trans | DN-17, DN-09 |
| Removal | `removal.json` | Large objects; hard scenes (water, building fronts, fences, tiled ground); composites with the true background | RM-20, RM-21 |
| Glass | `glass.json` | Composites with the true transmitted photo; real photos taken through glass | RM-22 |

## Rules

- **The manifests here list CC0 photos, the repository's own fixtures, synthetic images and openly licensed evaluation data** (CC BY 4.0 or CC BY-SA 4.0, such as RawNIND's pairs, credited in `credit`). Only CC0, fixture and synthetic cases go into Redlamp Bench tasks. The owner's own photos go in a private manifest of the same name outside the repository, in `~/Library/Application Support/Redlamp/Benchmarks/`, with `path` sources; their files and results stay outside the repository too.
- **Nothing downloaded or rendered is committed.** Files go to `build/benchmarks/<set>/`; delete the folder when a round is finished.
- **Lightroom's results are references only.** They come back through Redlamp Bench into `~/Library/Application Support/Redlamp/Bench/Done/<task>/results/`, and are never committed, shipped or converted (AGENTS.md). Measurements made from them go into `results/` as numbers only (DEC-41). Publishing a comparison waits on DEC-13.
- **Every case says how it's scored:** `truth` (an exact answer exists: synthetic scenes and composites), `pair` (a clean frame of the same scene: RawNIND pairs), or `picks` (blind pairwise picks only).
- **raw.pixls.us is run by volunteers:** one download at a time, with a pause between, as `scripts/camera-bench-seed.py` does.

## Manifest format

```json
{
  "set": "removal",
  "version": 1,
  "cases": [
    {
      "id": "d7500-car",
      "group": "large",
      "source": { "fixture": "tests/fixtures/shoots/…/DSC_1234.NEF", "sha256": "…" },
      "licence": "CC0-1.0",
      "credit": "…",
      "file": "d7500-car.nef",
      "score": "picks",
      "notes": "A parked car a third of the frame across"
    }
  ]
}
```

A case's `source` is one of:

- `{"url": "…", "sha256": "…"}`: downloaded by `benchmarks.py fetch` and checked against its SHA-256.
- `{"fixture": "tests/fixtures/…", "sha256": "…"}`: a file the repository's fixture tasks already fetch (`mise run fixtures`, `mise run fixtures-shoots`), used where it is.
- `{"generator": "research/…/make_x.py", "args": ["--seed", "1"]}`: made by the set's own generator, run from the repository's root with `BENCHMARK_OUT` set to `build/benchmarks/<set>`, which writes the case's `file` (and its `truth`, when it has one). The same arguments make the same files every time.
- `{"path": "~/…"}`: private manifests only.

`licence` is `CC0-1.0`, `synthetic`, `CC-BY-4.0` or `CC-BY-SA-4.0` in the manifests here. Each set adds its own fields:

- **Denoise:** `camera`, `iso`, `cfa` (`bayer` or `xtrans`), `truth` (a synthetic case's clean mosaic) and `crops`, the regions to score and show, as `[x, y, width, height]` in raw pixels.
- **Removal:** `spots`, what to remove, as Remove spots (`{"circle": [x, y, radius]}` in the photo's pixels, or `{"mask": "<file>"}`, a mask listed as another case file) or a pick (`{"find": "car"}`, `{"click": [x, y]}`), and `expect`, what should be left ("driveway, wall and door").
- **Glass:** `truth` (a composite's transmitted photo) and `reflection` (its reflection layer).

## Commands

```bash
python3 research/benchmarks/benchmarks.py list                 # every case and whether its file is ready
python3 research/benchmarks/benchmarks.py fetch --set denoise   # download and check one set's files
python3 research/benchmarks/benchmarks.py fetch --synthetic     # and make the synthetic cases
```

Other scripts import `benchmarks.cases(set)` and `benchmarks.resolve(set, case)` to find a case's file.

## Lightroom's results

One Redlamp Bench task per set, at most 20 assets each (`.cursor/skills/redlamp-bench/SKILL.md`), made from the CC0 and synthetic cases. Each set's draft lives in `bench/<set>.json` and is made into a task with `redlamp task new --draft`. For denoise, a synthetic scene goes to Lightroom twice, as a noisy and a clean DNG: Lightroom's Denoise on the noisy one is scored against Lightroom's own render of the clean one, so its rendering doesn't count against it, and Redlamp is scored the same way against its own.

## Blind picks

`picks.py make <round> --pairs pairs.json` draws a canvas of pairs, each two methods' results for one case as A and B in random order, and keeps which is which in `build/benchmarks/picks/<round>/key.json`. The owner marks each pair in the canvas (A is better, about the same, B is better, and what's wrong); `picks.py analyse <round>` reads the marks from the canvas's data file with the key and writes the tallies to `results/picks-<round>.json`.

## Results

Each set's scorer writes `results/<set>-<round>.json`: per case, the method, its scores and the commit or model it ran; `picks-<round>.json` holds the blind picks. Rounds are named for what they compare and their date (`denoise-open-models-2026-11-01`).
