#!/usr/bin/env node
// A promo's storyboard sheet: a frame at every cue on its cue sheet, labelled, over its score's level.
//   node scripts/storyboard.mjs StarPromo9x16 --cues=src/star/cues.json --score=star/score.json
// Writes out/<composition>-storyboard.jpg (or --out=<file>). The frames go to public/review/<composition>/,
// which is never committed. --props='{"hook":"psst"}' passes props to the composition.

import { bundle } from "@remotion/bundler";
import { renderStill, selectComposition } from "@remotion/renderer";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderUntilPainted } from "./blank.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const option = (name, fallback) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const [id] = args.filter((a) => !a.startsWith("--"));
const cuesFile = option("cues", null);
if (!id || !cuesFile) {
  console.error("usage: node scripts/storyboard.mjs <composition> --cues=<cues.json> [--score=<score.json in public/>] [--out=file] [--props=json]");
  process.exit(1);
}
const extra = JSON.parse(option("props", "{}"));
const sheet = JSON.parse(readFileSync(path.resolve(root, cuesFile), "utf8"));
const beat = (60 / sheet.bpm) * sheet.fps;
const scoreFile = option("score", null);
const level = scoreFile && existsSync(path.join(root, "public", scoreFile)) ? JSON.parse(readFileSync(path.join(root, "public", scoreFile), "utf8")).level : [];

const serveUrl = await bundle({ entryPoint: path.join(root, "src/index.ts") });
const composition = await selectComposition({ serveUrl, id, inputProps: extra });
const inputProps = { ...composition.props, ...extra };
const dir = path.join(root, "public/review", id);
rmSync(dir, { recursive: true, force: true });
mkdirSync(dir, { recursive: true });

const shots = [];
for (const [cue, b] of Object.entries(sheet.cues).sort((a, c) => a[1] - c[1])) {
  const frame = Math.min(Math.round(b * beat), composition.durationInFrames - 1);
  const file = `${String(frame).padStart(4, "0")}-${cue}.jpg`;
  const output = path.join(dir, file);
  await renderUntilPainted(output, () => renderStill({ composition, serveUrl, frame, output, imageFormat: "jpeg", jpegQuality: 85, scale: 0.5, inputProps }));
  shots.push({ src: `review/${id}/${file}`, cue, beat: b, seconds: frame / composition.fps });
  console.log(`${cue} (frame ${frame})`);
}

const board = await bundle({ entryPoint: path.join(root, "src/index.ts") });
const storyboardProps = {
  title: `${id}: storyboard`,
  shots,
  aspect: composition.width / composition.height,
  columns: composition.width / composition.height < 0.8 ? 9 : 6,
  level,
  frames: composition.durationInFrames,
  fps: composition.fps,
};
const still = await selectComposition({ serveUrl: board, id: "Storyboard", inputProps: storyboardProps });
const output = path.resolve(root, option("out", `out/${id}-storyboard.jpg`));
mkdirSync(path.dirname(output), { recursive: true });
await renderStill({ composition: still, serveUrl: board, output, imageFormat: "jpeg", jpegQuality: 88, inputProps: storyboardProps });
console.log(path.relative(process.cwd(), output));
