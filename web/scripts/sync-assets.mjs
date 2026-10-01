#!/usr/bin/env node
// Copies the screenshots, film assets and brand files the website and the explainer video
// use from docs/ into each project's public/synced, so they are never committed twice.
// On Vercel this needs "Include files outside the root directory in the Build Step".

import { cpSync, existsSync, mkdirSync, rmSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const docs = path.join(repo, "docs");

const sources = [
  { from: path.join(docs, "images"), to: "images", filter: (name) => /\.(png|jpe?g)$/i.test(name) },
  { from: path.join(docs, "images", "film"), to: "film" },
  { from: path.join(docs, "brand", "images"), to: "brand/images" },
  { from: path.join(docs, "brand", "logo"), to: "brand/logo" },
];

const targets = [path.join(repo, "web", "public", "synced"), path.join(repo, "video", "public", "synced")].filter(
  (target) => existsSync(path.dirname(path.dirname(target))),
);

for (const { from } of sources) {
  if (!existsSync(from)) {
    console.error(`sync-assets: ${path.relative(repo, from)} is missing.`);
    console.error("On Vercel, enable “Include files outside the root directory in the Build Step”.");
    process.exit(1);
  }
}

let copied = 0;
for (const target of targets) {
  rmSync(target, { recursive: true, force: true });
  for (const { from, to, filter } of sources) {
    const dest = path.join(target, to);
    mkdirSync(dest, { recursive: true });
    for (const entry of readdirSync(from, { withFileTypes: true })) {
      if (!entry.isFile() || (filter && !filter(entry.name))) continue;
      cpSync(path.join(from, entry.name), path.join(dest, entry.name));
      copied += 1;
    }
  }
}

console.log(`sync-assets: ${copied} files into ${targets.map((t) => path.relative(repo, t)).join(", ")}`);
