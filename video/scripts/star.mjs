#!/usr/bin/env node
// Renders the star promo into out/star/: the 9:16 and 1:1 cuts as H.264 MP4s with their score, and
// a poster for each. The badge shows the repository's star count as GitHub reports it now.
//   npm run star                        both cuts, with the default hook
//   npm run star -- StarPromo9x16        just one
//   npm run star -- --hook=psst          another hook (files get its name), or --hooks for every one
//   npm run star -- --no-count           the badge's star without the count
//   npm run star -- --draft              half size, for a quick look on a phone
// In the agent sandbox, run it with NODE_USE_ENV_PROXY=1 so the count can reach GitHub.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(root, "out/star");
const repo = "pdcgomes/redlamp";
const jobs = [
  { id: "StarPromo9x16", file: "star-redlamp-9x16" },
  { id: "StarPromo1x1", file: "star-redlamp-1x1" },
];
// The poster is the sign hanging under the badge: the ask, in one picture.
const POSTER = 300;

const args = process.argv.slice(2);
const only = args.filter((a) => !a.startsWith("--"));
const option = (name) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const draft = args.includes("--draft");
const copy = readFileSync(path.join(root, "src/star/copy.ts"), "utf8");
const hookBlock = copy.slice(copy.indexOf("export const hooks"), copy.indexOf("} as const"));
const allHooks = [...hookBlock.matchAll(/^\s+(\w+): \[/gm)].map((m) => m[1]);
const hooks = args.includes("--hooks") ? allHooks : [option("hook") ?? "charging"];
for (const hook of hooks) {
  if (!allHooks.includes(hook)) {
    console.error(`error: no hook named ${hook}; the hooks are ${allHooks.join(", ")}`);
    process.exit(1);
  }
}

let stars = null;
if (!args.includes("--no-count")) {
  try {
    const response = await fetch(`https://api.github.com/repos/${repo}`, { signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
    stars = (await response.json()).stargazers_count ?? null;
    console.log(`==> ${repo} has ${stars} stars`);
  } catch (error) {
    console.error(`error: couldn't read the star count (${error.message}); pass --no-count to render without it`);
    process.exit(1);
  }
}

if (!existsSync(path.join(root, "public/star/score.wav"))) {
  execFileSync("python3", ["scripts/star-score.py"], { cwd: root, stdio: "inherit" });
}

// Remotion fetches the score from its own server on localhost; through the sandbox's proxy that
// request never returns and the encode stalls, so only this script's GitHub request uses it.
const { NODE_USE_ENV_PROXY: _, ...env } = process.env;
env.NO_PROXY = env.no_proxy = ["localhost", "127.0.0.1", "::1", env.NO_PROXY].filter(Boolean).join(",");
const remotion = (...a) => execFileSync("npx", ["remotion", ...a], { cwd: root, stdio: "inherit", env });
mkdirSync(out, { recursive: true });
for (const job of jobs.filter((j) => only.length === 0 || only.includes(j.id))) {
  for (const hook of hooks) {
    const props = JSON.stringify({ hook, stars, musicSrc: "star/score.wav", guides: false });
    const name = `${job.file}${hooks.length > 1 || hook !== "charging" ? `-${hook}` : ""}${draft ? "-draft" : ""}`;
    const scale = draft ? ["--scale=0.5"] : [];
    // CRF 16, limited-range BT.709 4:2:0, which every site and player reads the same way.
    remotion("render", job.id, path.join(out, `${name}.mp4`), `--props=${props}`, "--codec=h264", "--crf=16", "--pixel-format=yuv420p", "--color-space=bt709", "--audio-bitrate=320k", "--audio-codec=aac", ...scale);
    if (!draft) {
      remotion("still", job.id, path.join(out, `${name}-poster.jpg`), `--props=${props}`, `--frame=${POSTER}`, "--image-format=jpeg", "--jpeg-quality=92");
    }
  }
}
