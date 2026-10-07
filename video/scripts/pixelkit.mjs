#!/usr/bin/env node
// Renders the pixelkit promo into out/pixelkit/: the 16:9 cut as an H.264 MP4 with its score, and a
// poster. Draws the frames and writes the score first if either is missing.
//   npm run pixelkit                    the default hook
//   npm run pixelkit -- --hook=bedroom  another hook (files get its name), or --hooks for every one
//   npm run pixelkit -- --draft         half size, for a quick look on a phone
//   npm run pixelkit -- --fresh         draw the frames and write the score again first

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderUntilPainted } from "./blank.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(root, "out/pixelkit");
const job = { id: "PixelkitPromo16x9", file: "pixelkit-16x9" };
// The poster is the CONTINUE? screen counting down: the ask, in one picture.
const POSTER = 820;

const args = process.argv.slice(2);
const option = (name) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const draft = args.includes("--draft");
const allHooks = Object.keys(JSON.parse(readFileSync(path.join(root, "src/pixelkit/copy.json"), "utf8")).hooks);
const hooks = args.includes("--hooks") ? allHooks : [option("hook") ?? allHooks[0]];
for (const hook of hooks) {
  if (!allHooks.includes(hook)) {
    console.error(`error: no hook named ${hook}; the hooks are ${allHooks.join(", ")}`);
    process.exit(1);
  }
}

const fresh = args.includes("--fresh");
if (fresh || !existsSync(path.join(root, "public/pixelkit/frames/0000.png"))) {
  execFileSync("python3", ["scripts/pixelkit-frames.py", "--hooks"], { cwd: root, stdio: "inherit" });
}
if (fresh || !existsSync(path.join(root, "public/pixelkit/score.wav"))) {
  execFileSync("python3", ["scripts/pixelkit-score.py"], { cwd: root, stdio: "inherit" });
}

// Remotion fetches the frames and the score from its own server on localhost; keep that off the
// sandbox's proxy, or the encode stalls.
const { NODE_USE_ENV_PROXY: _, ...env } = process.env;
env.NO_PROXY = env.no_proxy = ["localhost", "127.0.0.1", "::1", env.NO_PROXY].filter(Boolean).join(",");
const remotion = (...a) => execFileSync("npx", ["remotion", ...a], { cwd: root, stdio: "inherit", env });
mkdirSync(out, { recursive: true });
for (const hook of hooks) {
  const props = JSON.stringify({ hook, musicSrc: "pixelkit/score.wav" });
  const name = `${job.file}${hooks.length > 1 || hook !== allHooks[0] ? `-${hook}` : ""}${draft ? "-draft" : ""}`;
  const scale = draft ? ["--scale=0.5"] : [];
  // CRF 16, limited-range BT.709 4:2:0, as the studio's other promos.
  const video = path.join(out, `${name}.mp4`);
  await renderUntilPainted(video, () =>
    remotion("render", job.id, video, `--props=${props}`, "--codec=h264", "--crf=16", "--pixel-format=yuv420p", "--color-space=bt709", "--audio-bitrate=320k", "--audio-codec=aac", ...scale),
  );
  if (!draft) {
    const poster = path.join(out, `${name}-poster.jpg`);
    await renderUntilPainted(poster, () => remotion("still", job.id, poster, `--props=${props}`, `--frame=${POSTER}`, "--image-format=jpeg", "--jpeg-quality=92"));
  }
}
