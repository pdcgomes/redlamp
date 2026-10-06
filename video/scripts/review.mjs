#!/usr/bin/env node
// Renders stills of a composition for review, from one bundle:
//   node scripts/review.mjs StarPromo1x1 0,90,165,180            the frames named
//   node scripts/review.mjs StarPromo9x16 --cues=src/star/cues.json  every cue on a promo's cue sheet
// Options: --out=<dir> (default /tmp/review), --scale=0.5 for smaller stills, --props='{"guides":true}'.
// Each still is named <composition>-<frame>[-<cue>].jpg.

import { bundle } from "@remotion/bundler";
import { renderStill, selectComposition } from "@remotion/renderer";
import { mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const option = (name, fallback) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const [id, list] = args.filter((a) => !a.startsWith("--"));
if (!id) {
  console.error("usage: node scripts/review.mjs <composition> [frame,frame,…] [--cues=<cues.json>] [--out=dir] [--scale=n] [--props=json]");
  process.exit(1);
}
const dir = option("out", "/tmp/review");
const scale = Number(option("scale", "1"));
const extra = JSON.parse(option("props", "{}"));

let frames = (list ?? "").split(",").filter(Boolean).map((f) => ({ frame: Number(f), name: "" }));
const cuesFile = option("cues", null);
if (cuesFile) {
  const sheet = JSON.parse(readFileSync(path.resolve(root, cuesFile), "utf8"));
  const beat = (60 / sheet.bpm) * sheet.fps;
  frames = frames.concat(Object.entries(sheet.cues).map(([name, b]) => ({ frame: Math.round(b * beat), name })));
}

mkdirSync(dir, { recursive: true });
const serveUrl = await bundle({ entryPoint: path.join(root, "src/index.ts") });
const composition = await selectComposition({ serveUrl, id, inputProps: extra });
const inputProps = { ...composition.props, ...extra };
for (const { frame, name } of frames) {
  const clamped = Math.min(Math.max(frame, 0), composition.durationInFrames - 1);
  const output = path.join(dir, `${id}-${String(clamped).padStart(4, "0")}${name ? `-${name}` : ""}.jpg`);
  await renderStill({ composition, serveUrl, frame: clamped, output, imageFormat: "jpeg", jpegQuality: 88, scale, inputProps });
  console.log(path.relative(process.cwd(), output));
}
