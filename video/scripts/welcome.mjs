#!/usr/bin/env node
// Renders the app's welcome window (src/introducing/Welcome.tsx) into the app's resources, as
// apps/RedlampMac/Resources/Welcome.mp4: the film's opening as it is, then the logo rising to the
// top, where the window's pages appear, with its score.
//   npm run welcome
// The score is public/film/score-welcome.wav (python3 scripts/score.py welcome), which this writes
// if it's missing.

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.resolve(root, "../apps/RedlampMac/Resources/Welcome.mp4");
const remotion = (...a) => execFileSync("npx", ["remotion", ...a], { cwd: root, stdio: "inherit" });

if (!existsSync(path.join(root, "public/film/score-welcome.wav"))) {
  execFileSync("python3", ["scripts/score.py", "welcome"], { cwd: root, stdio: "inherit" });
}
const work = mkdtempSync(path.join(tmpdir(), "redlamp-welcome-"));
const master = path.join(work, "welcome.mov");
try {
  remotion("render", "Welcome", master, "--codec=prores", "--prores-profile=4444", "--image-format=png", "--color-space=bt709");
  // The pages sit on the last frame for as long as they're read, and 8 bits band the glow's dark
  // gradient there once the encoder smooths its grain away; HEVC in 10 bits (Main10) keeps it smooth
  // at a few megabytes. VideoToolbox encodes it (Remotion's x265 is 8-bit only), and AVFoundation
  // plays it only tagged hvc1.
  remotion(
    "ffmpeg", "-v", "error", "-y", "-i", master,
    "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-q:v", "80", "-tag:v", "hvc1",
    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
    "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", out,
  );
  console.log(`==> ${path.relative(path.resolve(root, ".."), out)}`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
