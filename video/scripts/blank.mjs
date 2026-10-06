// Catches frames headless Chrome captured before it had painted them. On a busy machine (seen at a
// load average over 100) it has captured whole frames as a flat white page, and stills with a layer
// missing (a canvas's light, so the frame comes out darker); a still renders in a fresh tab, so stills
// suffer most. A render is deterministic, so a frame that's right comes out the same every time:
// a still is accepted once two renders agree, and a video once no frame is white or stands out from
// both of its neighbours. The promos are dark, so no real frame comes near white (the brightest, a
// hit's flash, averages under 40 of 255); a promo with bright pictures needs another test.

import { execFileSync } from "node:child_process";
import { copyFileSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundled = path.join(root, "node_modules/@remotion/compositor-darwin-arm64");
const SIDE = 16;

/** Runs ffmpeg: the system's if there is one, else the one Remotion ships. */
function ffmpeg(args) {
  try {
    return execFileSync("ffmpeg", args, { maxBuffer: 1 << 28 });
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return execFileSync(path.join(bundled, "ffmpeg"), args, { maxBuffer: 1 << 28, env: { ...process.env, DYLD_LIBRARY_PATH: bundled } });
}

/** Every frame of an image or a video as a 16 × 16 grey thumbnail. */
function thumbnails(file) {
  // image2pipe with the rawvideo codec, as Remotion's own ffmpeg has no rawvideo muxer.
  const raw = ffmpeg(["-loglevel", "error", "-i", file, "-vf", `scale=${SIDE}:${SIDE},format=gray`, "-f", "image2pipe", "-c:v", "rawvideo", "-"]);
  const size = SIDE * SIDE;
  const frames = [];
  for (let i = 0; (i + 1) * size <= raw.length; i += 1) frames.push(raw.subarray(i * size, (i + 1) * size));
  return frames;
}

const mean = (a) => a.reduce((sum, v) => sum + v, 0) / a.length;
const apart = (a, b) => a.reduce((sum, v, i) => sum + Math.abs(v - b[i]), 0) / a.length;

/** The frames of an image (frame 0) or a video that came out white, or, in a video, stand out from both neighbours. */
export function unpaintedFrames(file) {
  const frames = thumbnails(file);
  const bad = [];
  frames.forEach((frame, i) => {
    if (mean(frame) > 150) {
      bad.push(i);
      return;
    }
    if (i === 0 || i === frames.length - 1) return;
    const between = frames[i - 1].map((v, j) => (v + frames[i + 1][j]) / 2);
    const jump = apart(frame, between);
    if (jump > 6 && jump > 3 * (apart(frames[i - 1], frames[i + 1]) + 1)) bad.push(i);
  });
  return bad;
}

/**
 * Runs `render`, which writes `file`, until the result can be trusted: for a video, until no frame is
 * unpainted; for a still, until two renders in a row agree. Gives up after `tries` renders.
 */
export async function renderUntilPainted(file, render, tries = 4) {
  const video = /\.(mp4|mov|webm|mkv)$/i.test(file);
  const previous = `${file}.previous`;
  try {
    for (let attempt = 1; attempt <= tries; attempt += 1) {
      await render();
      if (video) {
        const bad = unpaintedFrames(file);
        if (bad.length === 0) return;
        console.warn(`${path.basename(file)}: ${bad.length} frame(s) look unpainted (${bad.slice(0, 8).join(", ")}${bad.length > 8 ? ", …" : ""}); rendering it again`);
        continue;
      }
      if (unpaintedFrames(file).length === 0 && attempt > 1 && apart(thumbnails(file)[0], thumbnails(previous)[0]) < 2) return;
      copyFileSync(file, previous);
      if (attempt > 1) console.warn(`${path.basename(file)}: two renders disagree, so one wasn't painted; rendering it again`);
    }
  } finally {
    rmSync(previous, { force: true });
  }
  throw new Error(`${path.basename(file)} couldn't be rendered cleanly in ${tries} tries; render it when the machine is quieter`);
}
