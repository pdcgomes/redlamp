import assert from "node:assert/strict";
import { test } from "node:test";
import { issueNumbers, parseTracker, phaseCounts, trackerLink } from "./tracker.ts";

const tracker = `# Tracker

## 2. Phase 1: now

| ID | Item | Recommended | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1-01 | Process versions | Adopt | S | — | Accepted | Done (382f1ac) | DT |
| ARC-01 | Stage graph | Adopt | L | — | Accepted | In progress: the detail stage | DT |

## 9. Shapes

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SHP-03 | AI Sharpen | Build | P3–P4 | L | — | Proposed | Not started | H |
| SHP-04 | Bokeh gating | Build | With SHP-03 | S | — | Proposed | Blocked on SHP-03 | H |
| MSK-12 | Sky head | Build | P3 | XL | — | Proposed | Not needed for now | AI |
| FS-12 | Helicon comparison | Adopt | Now | S | — | Proposed | Not started | AI |
| OTH-02 | Culling | Adopt | With the library track | M | — | Rejected (2026-10-01) | Not started | AI |
| DEC-01 | A question | — | P3 | — | — | Accepted | Done | — |
`;

test("parseTracker reads each row's phase as tracker-issues.py does", () => {
  const phases = Object.fromEntries(parseTracker(tracker).map((row) => [row.id, row.phase]));
  assert.deepEqual(phases, { "P1-01": 1, "ARC-01": 1, "SHP-03": 3, "SHP-04": 3, "MSK-12": 3, "FS-12": 1, "OTH-02": null, "DEC-01": 3 });
});

test("parseTracker reads each row's status from the start of its Status cell", () => {
  const statuses = Object.fromEntries(parseTracker(tracker).map((row) => [row.id, row.status]));
  assert.equal(statuses["P1-01"], "done");
  assert.equal(statuses["ARC-01"], "in progress");
  assert.equal(statuses["SHP-04"], "blocked");
  assert.equal(statuses["MSK-12"], "not needed");
  assert.equal(statuses["SHP-03"], "not started");
});

test("phaseCounts leaves out decisions and work that isn't needed, and counts blocked work as not started", () => {
  assert.deepEqual(phaseCounts(parseTracker(tracker), 3), { done: 0, inProgress: 0, notStarted: 2 });
  assert.deepEqual(phaseCounts(parseTracker(tracker), 1), { done: 1, inProgress: 1, notStarted: 1 });
});

test("issueNumbers finds the sync's marker, else the title's prefix, and skips pull requests", () => {
  const numbers = issueNumbers([
    { number: 82, title: "LNS-04: Import LCP files", body: "Text\n<!-- tracker-id: LNS-04 -->" },
    { number: 90, title: "[MSK-18] Feature request", body: "From a user" },
    { number: 91, title: "Fix a crash", body: null },
    { number: 92, title: "TON-06: a pull request", body: "", pull_request: {} },
  ]);
  assert.deepEqual([...numbers], [["LNS-04", 82], ["MSK-18", 90]]);
});

test("trackerLink points at the issue when there is one, and searches for the ID otherwise", () => {
  const github = "https://github.com/pdcgomes/redlamp";
  assert.deepEqual(trackerLink("LNS-04", new Map([["LNS-04", 82]]), github), { href: `${github}/issues/82`, label: "#82" });
  const search = trackerLink("TON-06", new Map(), github);
  assert.equal(search.label, "TON-06");
  assert.equal(search.href, `${github}/issues?q=is%3Aissue%20%22TON-06%22`);
});
