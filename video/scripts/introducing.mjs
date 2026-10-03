#!/usr/bin/env node
// Renders "Introducing Redlamp" into out/introducing/: the 16:9 film and its 9:16 and 4:5 cuts as
// H.264 MP4s with their scores, a poster for each, two 9:16 PNGs to post as Stories ahead of the
// film, and on request a 4K master and ProRes masters.
//   npm run introducing                       every cut at 1080p, and the Stories
//   npm run introducing -- Introducing9x16    just one
//   npm run introducing -- --4k --prores      also a 3840 × 2160 master, and ProRes 422 HQ of each
// The pictures need public/film (scripts/capture-promo.sh, then npm run film-assets) and the
// scores public/film/score-*.wav (python3 scripts/score.py), which this writes if they're missing.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(root, "out/introducing");

const jobs = [
  { id: "Introducing", file: "introducing-redlamp-16x9", score: "film", poster: 470 },
  { id: "Introducing9x16", file: "introducing-redlamp-9x16", score: "short", poster: 640 },
  { id: "Introducing4x5", file: "introducing-redlamp-4x5", score: "short", poster: 640 },
];
const stories = [
  { id: "IntroducingStoryTitle", file: "introducing-redlamp-story-1-title" },
  { id: "IntroducingStoryEnd", file: "introducing-redlamp-story-2-end" },
];

const args = process.argv.slice(2);
const only = args.filter((a) => !a.startsWith("--"));
const remotion = (...a) => execFileSync("npx", ["remotion", ...a], { cwd: root, stdio: "inherit" });

if (!existsSync(path.join(root, "public/film/renders/manifest.json"))) {
  console.error("error: no public/film/renders; run scripts/capture-promo.sh and npm run film-assets first");
  process.exit(1);
}
for (const score of new Set(jobs.map((j) => j.score))) {
  if (!existsSync(path.join(root, `public/film/score-${score}.wav`))) {
    execFileSync("python3", ["scripts/score.py", score], { cwd: root, stdio: "inherit" });
  }
}

mkdirSync(out, { recursive: true });
for (const job of jobs.filter((j) => only.length === 0 || only.includes(j.id))) {
  const file = (suffix, ext) => path.join(out, `${job.file}${suffix}.${ext}`);
  // CRF 16, limited-range BT.709 4:2:0, which every site and player reads the same way.
  remotion("render", job.id, file("", "mp4"), "--codec=h264", "--crf=16", "--pixel-format=yuv420p", "--color-space=bt709", "--audio-bitrate=320k", "--audio-codec=aac");
  remotion("still", job.id, file("-poster", "jpg"), `--frame=${job.poster}`, "--image-format=jpeg", "--jpeg-quality=92");
  if (args.includes("--prores")) {
    remotion("render", job.id, file("", "mov"), "--codec=prores", "--prores-profile=hq");
  }
  if (args.includes("--4k") && job.id === "Introducing") {
    remotion("render", job.id, file("-4k", "mp4"), "--codec=h264", "--crf=16", "--pixel-format=yuv420p", "--color-space=bt709", "--scale=2", "--audio-bitrate=320k");
  }
}
for (const story of stories.filter((s) => only.length === 0 || only.includes(s.id))) {
  remotion("still", story.id, path.join(out, `${story.file}.png`), "--image-format=png");
}
