import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { type Cameras, parseCameras } from "./cameras.ts";
import { type Comparison, parseComparison } from "./comparison.ts";

/**
 * The site reads the repository's own status documents (the README, the tracker and the Lightroom
 * comparison) when it builds, so they're never copied. Relative imports only, so `node --test` can load it.
 */

export type RepoFile = "README.md" | "docs/lightroom-comparison.md" | "docs/research/research-tracker.md" | "docs/cameras.md";

const cache = new Map<RepoFile, string>();

/** One of the status documents. Each path is spelled out, so the build traces those files and not the repository. */
export function readRepoFile(file: RepoFile): string {
  let text = cache.get(file);
  if (text === undefined) {
    if (file === "README.md") text = readFileSync(path.join(process.cwd(), "..", "README.md"), "utf8");
    else if (file === "docs/lightroom-comparison.md") {
      text = readFileSync(path.join(process.cwd(), "..", "docs", "lightroom-comparison.md"), "utf8");
    } else if (file === "docs/cameras.md") text = readFileSync(path.join(process.cwd(), "..", "docs", "cameras.md"), "utf8");
    else text = readFileSync(path.join(process.cwd(), "..", "docs", "research", "research-tracker.md"), "utf8");
    cache.set(file, text);
  }
  return text;
}

let comparisonCache: Comparison | null = null;

/** Redlamp and Lightroom compared, from docs/lightroom-comparison.md. */
export function comparison(): Comparison {
  comparisonCache ??= parseComparison(readRepoFile("docs/lightroom-comparison.md"));
  return comparisonCache;
}

let camerasCache: Cameras | null = null;

/** The cameras Redlamp reads, from docs/cameras.md. */
export function cameras(): Cameras {
  camerasCache ??= parseCameras(readRepoFile("docs/cameras.md"));
  return camerasCache;
}

/** The commit the site was built from: Vercel's, else the checkout's; null when neither is known. */
export function sourceCommit(): string | null {
  const vercel = process.env.VERCEL_GIT_COMMIT_SHA;
  if (vercel) return vercel.slice(0, 7);
  try {
    return execSync("git rev-parse --short HEAD", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim() || null;
  } catch {
    return null;
  }
}
