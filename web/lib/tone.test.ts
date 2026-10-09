import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CURVE_WHITE,
  anchorExposure,
  level8,
  lookCurve,
  lstar,
  luminanceOf,
  sceneLog,
  srgbDecode,
  srgbEncode,
  toneCurve,
} from "./tone.ts";

const near = (actual: number, expected: number, tolerance: number) =>
  assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} is not within ${tolerance} of ${expected}`);

test("the tone curve renders middle grey at L* 64.3, as the TON-39 note measured", () => {
  near(lstar(toneCurve(0.18)), 64.3, 0.05);
});

test("the tone curve reaches white four stops over middle grey, and not before", () => {
  near(CURVE_WHITE, 2.88, 1e-6);
  assert.equal(toneCurve(CURVE_WHITE), 1);
  assert.ok(toneCurve(2.8) < 1);
});

test("the tone curve's shoulder joins the filmic part without a step", () => {
  near(toneCurve(0.54358851 - 1e-7), toneCurve(0.54358851 + 1e-7), 1e-5);
});

test("a look's contrast pivots on middle grey", () => {
  near(lookCurve(0.18, "neutral"), toneCurve(0.18), 1e-9);
  assert.ok(lookCurve(0.5, "neutral") < lookCurve(0.5, "color"));
});

test("sRGB and L* write middle grey where photographers expect it", () => {
  assert.equal(level8(0.18), 118);
  assert.equal(level8(0.5), 188);
  near(lstar(0.18), 49.5, 0.01);
  near(srgbDecode(128 / 255), 0.216, 0.001);
});

test("encoding and decoding round-trip", () => {
  for (const y of [0.001, 0.02, 0.18, 0.5, 0.9]) {
    near(srgbDecode(srgbEncode(y)), y, 1e-9);
    near(luminanceOf(lstar(y)), y, 1e-9);
  }
});

test("the film looks' log encoding puts middle grey at 10 of 16.5 stops", () => {
  near(sceneLog(0.18), 10 / 16.5, 1e-9);
});

test("anchoring middle grey under Neutral gives the TON-39 note's model of the grey scale", () => {
  const exposure = anchorExposure(50.9, "neutral");
  near(exposure, -0.856, 0.001);
  const rendered = [20.5, 35.7, 50.9, 66.8, 81.3, 96.5].map((reference) =>
    lstar(lookCurve(luminanceOf(reference) * 2 ** exposure, "neutral")),
  );
  [15.0, 32.9, 50.9, 67.1, 78.4, 86.9].forEach((expected, index) => near(rendered[index], expected, 0.06));
});
