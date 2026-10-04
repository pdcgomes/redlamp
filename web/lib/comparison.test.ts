import assert from "node:assert/strict";
import { test } from "node:test";
import { parseComparison, statusCounts } from "./comparison.ts";

const header = "| Feature | Lightroom | Redlamp | vs Lightroom | Phase | Tracker | Notes |\n| --- | --- | --- | --- | --- | --- | --- |";

function doc(rows: string, group = "Detail"): string {
  return `# Compared\n\n**Lightroom checked against:** Lightroom Classic 14, as of mid-2025.\n\n## ${group}\n\n${header}\n${rows}\n`;
}

test("parseComparison reads each group's rows and the Lightroom baseline", () => {
  const parsed = parseComparison(
    doc(
      [
        "| Sharpening | Yes | Done | | | SHP-01 | Lightroom's four controls |",
        "| AI Denoise | Yes | Planned | | P3 | DN-07, DN-08 | On the Mac |",
        "| Generative Remove | Yes (cloud, credits) | Planned | | P3 | RM-10 | |",
      ].join("\n"),
    ),
  );
  assert.equal(parsed.checkedAgainst, "Lightroom Classic 14, as of mid-2025.");
  assert.equal(parsed.groups.length, 1);
  const [sharpening, denoise, remove] = parsed.groups[0].rows;
  assert.deepEqual(sharpening, {
    feature: "Sharpening",
    lightroom: { has: "Yes", qualifier: null },
    status: "Done",
    versus: null,
    phase: null,
    tracker: ["SHP-01"],
    notes: "Lightroom's four controls",
  });
  assert.equal(denoise.phase, 3);
  assert.deepEqual(denoise.tracker, ["DN-07", "DN-08"]);
  assert.deepEqual(remove.lightroom, { has: "Yes", qualifier: "cloud, credits" });
});

test("parseComparison starts a group at each heading", () => {
  const markdown = doc("| Grain | Yes | Done | | | | |", "Effects") + `\n## Masking\n\n${header}\n| Brush | Yes | Done | | | MSK-16 | |\n`;
  assert.deepEqual(
    parseComparison(markdown).groups.map((group) => group.title),
    ["Effects", "Masking"],
  );
});

test("parseComparison names the line and the feature of a row with an unknown status", () => {
  assert.throws(() => parseComparison(doc("| Grain | Yes | Shipped | | | | |")), /line 9 \(Grain\): Redlamp must be one of/);
});

test("parseComparison keeps vs Lightroom to Done rows", () => {
  assert.throws(() => parseComparison(doc("| Grain | Yes | Planned | Beyond | P3 | | |")), /only for Done rows/);
  assert.throws(() => parseComparison(doc("| Grain | Yes | Done | Better | | | |")), /vs Lightroom must be blank or one of/);
});

test("parseComparison needs a Phase on Planned rows, and none on Done, Later or Out of scope rows", () => {
  assert.throws(() => parseComparison(doc("| Grain | Yes | Planned | | | | |")), /needs its Phase/);
  assert.throws(() => parseComparison(doc("| Grain | Yes | Done | | P2 | | |")), /only Planned and In progress rows/);
  assert.equal(parseComparison(doc("| Grain | Yes | In progress | | P2 | | |")).groups[0].rows[0].phase, 2);
});

test("parseComparison rejects a Lightroom value that isn't Yes, Partly or No", () => {
  assert.throws(() => parseComparison(doc("| Grain | Sort of | Done | | | | |")), /Lightroom must be Yes, Partly or No/);
});

test("statusCounts counts every row once", () => {
  const { groups } = parseComparison(
    doc(["| A | Yes | Done | | | | |", "| B | No | Done | | | | |", "| C | Yes | Later | | | | |"].join("\n")),
  );
  assert.deepEqual(statusCounts(groups), { Done: 2, "In progress": 0, Planned: 0, Later: 1, "Out of scope": 0 });
});
