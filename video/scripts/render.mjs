#!/usr/bin/env node
// Renders the explainer and its social cut-downs into out/, each with a poster still, and
// writes a web-sized 16:9 copy and poster into ../web/public/video for the website.
//   npm run render                 every cut
//   npm run render -- Social9x16   just one

import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const web = path.resolve(root, "../web/public/video");
const out = path.join(root, "out");

const jobs = [
  { id: "Explainer", file: "redlamp-explainer-16x9", poster: 196 },
  { id: "Social9x16", file: "redlamp-explainer-9x16", poster: 196 },
  { id: "Social1x1", file: "redlamp-explainer-1x1", poster: 196 },
];

const only = process.argv.slice(2);
const remotion = (...args) => execFileSync("npx", ["remotion", ...args], { cwd: root, stdio: "inherit" });

mkdirSync(out, { recursive: true });
for (const job of jobs.filter((j) => only.length === 0 || only.includes(j.id))) {
  remotion("render", job.id, path.join(out, `${job.file}.mp4`), "--codec=h264", "--crf=18");
  remotion("still", job.id, path.join(out, `${job.file}-poster.jpg`), `--frame=${job.poster}`, "--image-format=jpeg");

  if (job.id === "Explainer") {
    mkdirSync(web, { recursive: true });
    remotion(
      "ffmpeg",
      "-y",
      "-i",
      path.join(out, `${job.file}.mp4`),
      "-vf",
      "scale=1280:-2",
      "-c:v",
      "libx264",
      "-crf",
      "25",
      "-preset",
      "slow",
      "-pix_fmt",
      "yuv420p",
      "-movflags",
      "+faststart",
      path.join(web, "redlamp-explainer.mp4"),
    );
    remotion(
      "still",
      job.id,
      path.join(web, "redlamp-explainer-poster.jpg"),
      `--frame=${job.poster}`,
      "--image-format=jpeg",
      "--scale=0.6667",
    );
  }
}
