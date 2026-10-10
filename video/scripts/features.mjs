#!/usr/bin/env node
// Renders a feature video (docs/plans/2026-10-10-feature-videos.md) into ~/src/redlamp-social/renders/,
// named by its post's file in docs/social/posts.json (e01-a.mp4), as H.264 at 1080 × 1920 with its
// score, and the cover each post uses (its coverMs) as a JPEG beside it. Draws the frames and writes the
// score first if either is missing.
//   npm run features -- --episode=e01            every hook the episode posts with
//   npm run features -- --episode=e01 --hook=b   one hook
//   npm run features -- --episode=e01 --draft    half size, for a quick look on a phone (…-draft.mp4)
//   npm run features -- --episode=e01 --draft --score=score-pulse   another arrangement (…-pulse-draft.mp4)
//   npm run features -- --episode=e01 --fresh    draw the frames and write the score again first

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderUntilPainted } from "./blank.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(os.homedir(), "src/redlamp-social/renders");
const ID = "FeatureVideo";
const FPS = 30;

const args = process.argv.slice(2);
const option = (name) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const episode = option("episode")?.toLowerCase();
const draft = args.includes("--draft");
const fresh = args.includes("--fresh");
const score = option("score") ?? "score";
const schedule = JSON.parse(readFileSync(path.join(root, "../docs/social/posts.json"), "utf8"));
const known = schedule.episodes.map((e) => e.id);
if (!episode || !known.includes(episode)) {
  console.error(`usage: npm run features -- --episode=<${known.join("|")}> [--hook=<id>] [--draft] [--fresh]`);
  process.exit(1);
}
const posts = schedule.posts.filter((p) => p.episode === episode);
const hook = option("hook");
const chosen = hook ? posts.filter((p) => p.hook === hook) : posts;
if (chosen.length === 0) {
  console.error(`error: ${episode} has no post with hook ${hook}; its hooks are ${posts.map((p) => p.hook).join(", ")}`);
  process.exit(1);
}

const python = (script, ...rest) => execFileSync("python3", [script, "--episode", episode, ...rest], { cwd: root, stdio: "inherit" });
if (fresh || !existsSync(path.join(root, `public/features/${episode}/frames.json`))) python("scripts/features-frames.py");
if (fresh || !existsSync(path.join(root, `public/features/${episode}/score.wav`))) python("scripts/features-score.py");
const manifest = JSON.parse(readFileSync(path.join(root, `public/features/${episode}/frames.json`), "utf8"));
for (const post of chosen) {
  if (!manifest.frames[post.hook]) {
    console.error(`error: public/features/${episode}/frames.json has no frames for hook ${post.hook}; run with --fresh`);
    process.exit(1);
  }
}
if (!existsSync(path.join(root, `public/features/${episode}/${score}.wav`))) {
  console.error(`error: public/features/${episode}/${score}.wav doesn't exist; scripts/features-score.py writes score.wav and score-<arrangement>.wav`);
  process.exit(1);
}
if (manifest.standIn) console.warn(`note: ${episode}'s real result is a stand-in edit until the owner's own is saved beside the raw`);

// Remotion fetches the frames and the score from its own server on localhost; keep that off the
// sandbox's proxy, or the encode stalls.
const { NODE_USE_ENV_PROXY: _, ...env } = process.env;
env.NO_PROXY = env.no_proxy = ["localhost", "127.0.0.1", "::1", env.NO_PROXY].filter(Boolean).join(",");
const remotion = (...a) => execFileSync("npx", ["remotion", ...a], { cwd: root, stdio: "inherit", env });
mkdirSync(out, { recursive: true });
for (const post of chosen) {
  const props = JSON.stringify({ episode, hook: post.hook, score, guides: false });
  const variant = score === "score" ? "" : `-${score.replace(/^score-/, "")}`;
  const name = post.file.replace(/\.mp4$/, `${variant}${draft ? "-draft" : ""}`);
  const scale = draft ? ["--scale=0.5"] : [];
  // CRF 16, limited-range BT.709 4:2:0, as the studio's other promos.
  const video = path.join(out, `${name}.mp4`);
  await renderUntilPainted(video, () =>
    remotion("render", ID, video, `--props=${props}`, "--codec=h264", "--crf=16", "--pixel-format=yuv420p", "--color-space=bt709", "--audio-bitrate=320k", "--audio-codec=aac", ...scale),
  );
  if (!draft) {
    const cover = path.join(out, `${name}-cover.jpg`);
    const frame = Math.round((post.coverMs / 1000) * FPS);
    await renderUntilPainted(cover, () => remotion("still", ID, cover, `--props=${props}`, `--frame=${frame}`, "--image-format=jpeg", "--jpeg-quality=92"));
  }
  console.log(path.relative(process.cwd(), video));
}
