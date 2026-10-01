#!/usr/bin/env node
// Renders the Reddit stills (src/stills) into out/stills at 2880 × 1800: a PNG master and a JPEG
// for uploading.
//   npm run stills                    every still
//   npm run stills -- still-01-hero   just the ones named

import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(root, "out", "stills");
const run = (command, args, options = {}) => execFileSync(command, args, { cwd: root, stdio: "inherit", ...options });

const listed = execFileSync("npx", ["remotion", "compositions", "--quiet"], { cwd: root, encoding: "utf8" });
const ids = listed.split(/\s+/).filter((id) => id.startsWith("still-"));
const only = process.argv.slice(2);
const unknown = only.filter((id) => !ids.includes(id));
if (unknown.length > 0) {
  console.error(`stills: no still named ${unknown.join(", ")}. The stills are: ${ids.join(", ")}`);
  process.exit(1);
}

mkdirSync(out, { recursive: true });
for (const id of ids.filter((id) => only.length === 0 || only.includes(id))) {
  const png = path.join(out, `${id}.png`);
  run("npx", ["remotion", "still", id, png, "--scale=2", "--image-format=png", "--log=error"]);
  run("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "92", png, "--out", png.replace(/\.png$/, ".jpg")], {
    stdio: "ignore",
  });
  console.log(`==> ${path.relative(root, png)}`);
}
