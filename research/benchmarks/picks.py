#!/usr/bin/env python3
"""Blind pairwise picks for the benchmarks (INF-14): a canvas of A and B pairs, then the tallies.

    research/benchmarks/picks.py make <round> --pairs pairs.json --question "…" [--tags "Soft,Seam"]
        [--width 1024] [--seed N]
    research/benchmarks/picks.py analyse <round>

`make` draws picks-<round>.canvas.tsx in Cursor's canvases folder for this repository: each pair is
two methods' results for one case, as A and B in random order, scaled to at most --width pixels wide.
Which is which is kept apart, in build/benchmarks/picks/<round>/key.json. The owner's marks are kept
in the canvas's data file; `analyse` reads them with the key and writes results/picks-<round>.json.

pairs.json is a list of {"case": "…", "a": {"method": "…", "image": "<path>"}, "b": {…},
"crop": [x, y, width, height]}; the crop is optional and the same for both images.

Needs Pillow (`uv pip install pillow` into any virtual environment under build/).
"""

import argparse
import base64
import io
import json
import pathlib
import random
from collections import Counter, defaultdict

from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
KEYS = ROOT / "build" / "benchmarks" / "picks"
RESULTS = HERE / "results"
CANVASES = pathlib.Path.home() / ".cursor" / "projects" / str(ROOT).strip("/").replace("/", "-") / "canvases"

TEMPLATE = """import { Button, Checkbox, Grid, H1, Pill, Row, Stack, Text, useCanvasState } from "cursor/canvas";

// Blind picks for the benchmarks (research/benchmarks/picks.py make draws it). Each pair is two methods'
// results for one case, as A and B in random order; which is which is kept apart, in the round's key.
// The marks are kept in this canvas's data file, which picks.py analyse reads.

type Item = { id: string; title: string; a: string; b: string };
type Mark = { choice?: string; what?: string[] };
const ROUND = __ROUND__;
const QUESTION = __QUESTION__;
const ITEMS: Item[] = __ITEMS__;
const CHOICES: [string, string][] = [["a", "A is better"], ["same", "About the same"], ["b", "B is better"]];
const WHAT: string[] = __WHAT__;

export default function BlindPicks() {
  const [marks, setMarks] = useCanvasState<Record<string, Mark>>("picks", {});
  const [index, setIndex] = useCanvasState<number>("index", 0);
  const item = ITEMS[Math.min(index, ITEMS.length - 1)];
  const mark = marks[item.id] ?? {};
  const done = ITEMS.filter((i) => marks[i.id]?.choice).length;
  const update = (change: Mark) => setMarks((prev) => ({ ...prev, [item.id]: { ...prev[item.id], ...change } }));
  const toggle = (w: string, on: boolean) => {
    const what = new Set(mark.what ?? []);
    if (on) what.add(w);
    else what.delete(w);
    update({ what: [...what] });
  };
  return (
    <Stack gap={16} style={{ padding: 20 }}>
      <H1>{QUESTION}</H1>
      <Text tone="secondary">
        {`A and B are two methods' results for the same photo, in random order. Round ${ROUND}: ${done} of ${ITEMS.length} marked.`}
      </Text>
      <Row gap={12} align="center">
        <Text weight="semibold">{`Pair ${index + 1} of ${ITEMS.length}: ${item.title}`}</Text>
        <Button variant="secondary" disabled={index === 0} onClick={() => setIndex(Math.max(0, index - 1))}>
          Previous
        </Button>
        <Button
          variant="secondary"
          disabled={index >= ITEMS.length - 1}
          onClick={() => setIndex(Math.min(ITEMS.length - 1, index + 1))}
        >
          Next
        </Button>
      </Row>
      <Grid columns={2} gap={12}>
        <Stack gap={6}>
          <Text weight="semibold">A</Text>
          <img src={item.a} style={{ width: "100%", display: "block" }} />
        </Stack>
        <Stack gap={6}>
          <Text weight="semibold">B</Text>
          <img src={item.b} style={{ width: "100%", display: "block" }} />
        </Stack>
      </Grid>
      <Row gap={8} wrap>
        {CHOICES.map(([id, label]) => (
          <Pill
            key={id}
            active={mark.choice === id}
            onClick={() => {
              update({ choice: id });
              if (index < ITEMS.length - 1 && !mark.choice) setIndex(index + 1);
            }}
          >
            {label}
          </Pill>
        ))}
      </Row>
      {WHAT.length > 0 && (
        <Stack gap={6}>
          <Text tone="secondary" size="small">
            What's wrong with the worse one, if anything (optional)
          </Text>
          <Row gap={12} wrap>
            {WHAT.map((w) => (
              <Checkbox key={w} label={w} checked={(mark.what ?? []).includes(w)} onChange={(on) => toggle(w, on)} />
            ))}
          </Row>
        </Stack>
      )}
    </Stack>
  );
}
"""


def encode(path, crop, width):
    image = Image.open(path).convert("RGB")
    if crop:
        x, y, w, h = crop
        image = image.crop((x, y, x + w, y + h))
    if image.width > width:
        image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
    buffer = io.BytesIO()
    # Full-resolution chroma and a high quality, so compression doesn't hide or add noise between methods.
    image.save(buffer, "JPEG", quality=95, subsampling=0)
    return "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode()


def make(round_name, pairs_path, question, tags, width, seed):
    pairs = json.loads(pathlib.Path(pairs_path).read_text())
    shuffle = random.Random(seed if seed is not None else round_name)
    items, key = [], {}
    for index, pair in enumerate(pairs, 1):
        item_id = f"p{index:02d}"
        first, second = pair["a"], pair["b"]
        if shuffle.random() < 0.5:
            first, second = second, first
        crop = pair.get("crop")
        items.append(
            {
                "id": item_id,
                "title": pair["case"],
                "a": encode(first["image"], crop, width),
                "b": encode(second["image"], crop, width),
            }
        )
        key[item_id] = {"case": pair["case"], "a": first["method"], "b": second["method"]}

    keys = KEYS / round_name
    keys.mkdir(parents=True, exist_ok=True)
    (keys / "key.json").write_text(json.dumps({"round": round_name, "question": question, "items": key}, indent=2) + "\n")
    canvas = CANVASES / f"picks-{round_name}.canvas.tsx"
    source = (
        TEMPLATE.replace("__ROUND__", json.dumps(round_name))
        .replace("__QUESTION__", json.dumps(question))
        .replace("__WHAT__", json.dumps(tags))
        .replace("__ITEMS__", json.dumps(items))
    )
    canvas.write_text(source)
    print(f"{len(items)} pairs in {canvas} ({canvas.stat().st_size / 1e6:.1f} MB); key in {keys / 'key.json'}")


def analyse(round_name):
    key = json.loads((KEYS / round_name / "key.json").read_text())
    data = CANVASES / f"picks-{round_name}.canvas.data.json"
    marks = json.loads(data.read_text()).get("picks", {}) if data.exists() else {}
    tally = defaultdict(Counter)
    worse_for = defaultdict(Counter)
    cases = []
    for item_id, entry in key["items"].items():
        mark = marks.get(item_id, {})
        choice = mark.get("choice")
        if not choice:
            continue
        better = None
        if choice == "same":
            tally[entry["a"]]["ties"] += 1
            tally[entry["b"]]["ties"] += 1
        else:
            better, worse = (entry["a"], entry["b"]) if choice == "a" else (entry["b"], entry["a"])
            tally[better]["wins"] += 1
            tally[worse]["losses"] += 1
            for tag in mark.get("what", []):
                worse_for[worse][tag] += 1
        cases.append({"case": entry["case"], "methods": [entry["a"], entry["b"]], "better": better, "what": mark.get("what", [])})
    result = {
        "round": round_name,
        "question": key["question"],
        "marked": len(cases),
        "pairs": len(key["items"]),
        "methods": {
            method: {"wins": tally[method]["wins"], "ties": tally[method]["ties"], "losses": tally[method]["losses"], "worse_for": dict(worse_for[method])}
            for method in sorted(tally)
        },
        "cases": cases,
    }
    RESULTS.mkdir(exist_ok=True)
    out = RESULTS / f"picks-{round_name}.json"
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"{result['marked']} of {result['pairs']} pairs marked; tallies in {out}")
    for method, counts in result["methods"].items():
        print(f"  {method}: {counts['wins']} better, {counts['ties']} the same, {counts['losses']} worse")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    making = commands.add_parser("make")
    making.add_argument("round")
    making.add_argument("--pairs", required=True)
    making.add_argument("--question", required=True)
    making.add_argument("--tags", default="", help="comma-separated faults to tick on the worse one")
    making.add_argument("--width", type=int, default=1024)
    making.add_argument("--seed", type=int)
    analysing = commands.add_parser("analyse")
    analysing.add_argument("round")
    args = parser.parse_args()
    if args.command == "make":
        tags = [tag.strip() for tag in args.tags.split(",") if tag.strip()]
        make(args.round, args.pairs, args.question, tags, args.width, args.seed)
    else:
        analyse(args.round)


if __name__ == "__main__":
    main()
