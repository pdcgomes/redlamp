import assert from "node:assert/strict";
import { test } from "node:test";
import { itemState, parseRoadmap, phaseNumber } from "./readme.ts";

const readme = `# Redlamp

## Roadmap

The Mac comes first.

### Phase 2: Develop parity *(in progress)*
- [x] Crop and straighten <!-- tracker: LNS-06 -->
- [ ] Better X-Trans demosaicing (Markesteijn) <!-- tracker: CAM-07 -->
- [ ] Lens corrections from lensfun <!-- tracker: LNS-03, LNS-01 -->
- [ ] Performance lab <!-- internal -->
- [ ] Tiled exports on iPhone <!-- internal; tracker: ARC-05 -->

### Later
- A library and catalog <!-- tracker: OTH-04 -->

## Installation
`;

test("parseRoadmap reads each item's tracker rows and leaves the comment out of its text", () => {
  const { phases } = parseRoadmap(readme);
  assert.deepEqual(
    phases.map((phase) => [phase.title, phase.status]),
    [
      ["Phase 2: Develop parity", "in progress"],
      ["Later", null],
    ],
  );
  const [crop, xtrans, lensfun, lab, tiled] = phases[0].items;
  assert.deepEqual(crop, { text: "Crop and straighten", done: true, tracker: ["LNS-06"], internal: false });
  assert.deepEqual(xtrans.tracker, ["CAM-07"]);
  assert.deepEqual(lensfun.tracker, ["LNS-03", "LNS-01"]);
  assert.deepEqual([lab.internal, lab.tracker], [true, []]);
  assert.deepEqual([tiled.internal, tiled.tracker], [true, ["ARC-05"]]);
  assert.deepEqual(phases[1].items[0], { text: "A library and catalog", done: null, tracker: ["OTH-04"], internal: false });
});

test("itemState: ticked is done, unticked with a started row is in progress", () => {
  const status = (id: string) => ({ "LNS-01": "in progress", "LNS-03": "not started", "CAM-07": "not started" })[id];
  const items = parseRoadmap(readme).phases[0].items;
  assert.deepEqual(
    items.map((item) => itemState(item, status)),
    ["done", "not started", "in progress", "not started", "not started"],
  );
});

test("phaseNumber reads a phase heading's number", () => {
  assert.equal(phaseNumber("Phase 2: Develop parity"), 2);
  assert.equal(phaseNumber("Later"), null);
});
