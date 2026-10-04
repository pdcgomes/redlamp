import assert from "node:assert/strict";
import { test } from "node:test";
import { compare, formatChange, formatEntry, formatValue, histories, parseHistory, parseMetrics } from "./performance.ts";

const metrics = parseMetrics(
  JSON.stringify({
    groups: ["Editing", "Folders"],
    metrics: [
      { id: "render-fit", label: "Render at Fit", detail: "", unit: "ms", group: "Editing", better: "lower", measuredBy: ["bench"] },
      { id: "folders-warm", label: "Warming", detail: "", unit: "/s", group: "Folders", better: "higher", measuredBy: ["folders"] },
    ],
  }),
);

const line = (record: object) => JSON.stringify({ machine: { chip: "Apple M1 Ultra" }, noisy: false, source: "harness", ...record });

test("parseHistory sorts records by date and names the line of an unknown metric", () => {
  const records = parseHistory(
    [
      line({ date: "2026-10-02T10:00:00+01:00", commit: "b", metrics: { "render-fit": { value: 2 } } }),
      line({ date: "2026-10-01T10:00:00+01:00", commit: "a", metrics: { "render-fit": { value: 3 } } }),
    ].join("\n"),
    metrics,
  );
  assert.deepEqual(records.map((record) => record.commit), ["a", "b"]);
  assert.throws(() => parseHistory(line({ date: "2026-10-01", commit: "a", metrics: { nope: { value: 1 } } }), metrics), /line 1: unknown metric nope/);
});

test("parseMetrics rejects a metric whose group isn't listed", () => {
  assert.throws(
    () => parseMetrics(JSON.stringify({ groups: ["Editing"], metrics: [{ id: "x", group: "Other" }] })),
    /x's group "Other"/,
  );
});

const point = (value: number, extra: object = {}) => ({
  date: "2026-10-01",
  commit: "a",
  subject: "",
  source: "harness" as const,
  noisy: false,
  chip: "Apple M1 Ultra",
  entry: { value },
  ...extra,
});

test("compare: a move within 10% is noise; beyond it, lower is faster for times and slower for rates", () => {
  const render = metrics.metrics[0];
  const warm = metrics.metrics[1];
  assert.equal(compare(render, point(10), point(10.9)), null);
  assert.equal(compare(render, point(10), point(12))?.kind, "slower");
  assert.equal(compare(render, point(10), point(8))?.kind, "faster");
  assert.equal(compare(warm, point(700), point(500))?.kind, "slower");
});

test("compare: the runs' own spread raises the threshold", () => {
  const render = metrics.metrics[0];
  assert.equal(compare(render, point(10, { entry: { value: 10, spread: 0.3 } }), point(12)), null);
});

test("histories compares the latest run with the previous comparable one, and never a noisy run", () => {
  const records = parseHistory(
    [
      line({ date: "2026-09-30T10:00:00+01:00", commit: "readme1", source: "readme", metrics: { "render-fit": { value: 1.8, low: 0.6, high: 3 } } }),
      line({ date: "2026-10-01T10:00:00+01:00", commit: "h1", metrics: { "render-fit": { value: 4 } } }),
      line({ date: "2026-10-02T10:00:00+01:00", commit: "h2", metrics: { "render-fit": { value: 3 } } }),
      line({ date: "2026-10-03T10:00:00+01:00", commit: "h3", noisy: true, metrics: { "render-fit": { value: 9 } } }),
    ].join("\n"),
    metrics,
  );
  const [render] = histories(metrics, records);
  assert.equal(render.points.length, 4);
  assert.equal(render.current.commit, "h2");
  assert.equal(render.change, null, "the latest run is noisy, so nothing is compared");
  assert.equal(render.sinceFirst?.kind, "faster");
  assert.equal(render.sinceFirst?.from.commit, "h1", "README figures aren't compared with the harness's");
  assert.equal(render.best.commit, "h2");
});

test("histories reports a change when the latest run is quiet", () => {
  const records = parseHistory(
    [
      line({ date: "2026-10-01T10:00:00+01:00", commit: "h1", metrics: { "render-fit": { value: 3 } } }),
      line({ date: "2026-10-02T10:00:00+01:00", commit: "h2", metrics: { "render-fit": { value: 4 } } }),
    ].join("\n"),
    metrics,
  );
  const [render] = histories(metrics, records);
  assert.equal(render.change?.kind, "slower");
  assert.equal(render.change?.from.commit, "h1");
});

test("formatChange says less or more for memory", () => {
  const render = metrics.metrics[0];
  const faster = compare(render, point(10), point(5))!;
  assert.equal(formatChange(faster, "ms"), "50% faster");
  assert.equal(formatChange(faster, "GB"), "50% less");
});

test("formatValue and formatEntry write values and ranges as the site does", () => {
  assert.equal(formatValue(13, "ms"), "13 ms");
  assert.equal(formatValue(0.17, "ms"), "0.17 ms");
  assert.equal(formatValue(6210, "/s"), "6,210 a second");
  assert.equal(formatValue(34, "%"), "34%");
  assert.equal(formatEntry({ value: 1.8, low: 0.6, high: 3 }, "ms"), "0.6–3 ms");
});
