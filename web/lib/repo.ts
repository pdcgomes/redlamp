import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { type Cameras, parseCameras } from "./cameras.ts";
import { type Comparison, parseComparison } from "./comparison.ts";
import { type Metrics, parseHistory, parseMetrics, type RunRecord } from "./performance.ts";

/**
 * The site reads the repository's own status documents (the README, the tracker and the Lightroom
 * comparison) when it builds, so they're never copied. Relative imports only, so `node --test` can load it.
 */

export type RepoFile =
  | "README.md"
  | "docs/lightroom-comparison.md"
  | "docs/research/research-tracker.md"
  | "docs/cameras.md"
  | "docs/performance/metrics.json"
  | "docs/performance/history.jsonl"
  | "docs/camera-bench.schema.json"
  | "docs/camera-bench.json";

const cache = new Map<RepoFile, string>();

/** Each path is spelled out, so the build traces these files and not the whole repository. */
function load(file: RepoFile): string {
  switch (file) {
    case "README.md":
      return readFileSync(path.join(process.cwd(), "..", "README.md"), "utf8");
    case "docs/lightroom-comparison.md":
      return readFileSync(path.join(process.cwd(), "..", "docs", "lightroom-comparison.md"), "utf8");
    case "docs/research/research-tracker.md":
      return readFileSync(path.join(process.cwd(), "..", "docs", "research", "research-tracker.md"), "utf8");
    case "docs/cameras.md":
      return readFileSync(path.join(process.cwd(), "..", "docs", "cameras.md"), "utf8");
    case "docs/performance/metrics.json":
      return readFileSync(path.join(process.cwd(), "..", "docs", "performance", "metrics.json"), "utf8");
    case "docs/performance/history.jsonl":
      return readFileSync(path.join(process.cwd(), "..", "docs", "performance", "history.jsonl"), "utf8");
    case "docs/camera-bench.schema.json":
      return readFileSync(path.join(process.cwd(), "..", "docs", "camera-bench.schema.json"), "utf8");
    case "docs/camera-bench.json":
      return readFileSync(path.join(process.cwd(), "..", "docs", "camera-bench.json"), "utf8");
  }
}

/** One of the status documents. */
export function readRepoFile(file: RepoFile): string {
  let text = cache.get(file);
  if (text === undefined) {
    text = load(file);
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

let performanceCache: { metrics: Metrics; records: RunRecord[] } | null = null;

/** The performance metrics and their recorded history, from docs/performance/. */
export function performance(): { metrics: Metrics; records: RunRecord[] } {
  if (!performanceCache) {
    const metrics = parseMetrics(readRepoFile("docs/performance/metrics.json"));
    performanceCache = { metrics, records: parseHistory(readRepoFile("docs/performance/history.jsonl"), metrics) };
  }
  return performanceCache;
}

/** The camera bench report format (docs/camera-bench.schema.json), which the relay checks reports against. */
export function cameraBenchSchema(): Record<string, unknown> {
  return JSON.parse(readRepoFile("docs/camera-bench.schema.json")) as Record<string, unknown>;
}

/** The camera bench's public evidence (docs/camera-bench.json), or null before the aggregator first writes it. */
export function cameraBenchEvidence(): unknown {
  try {
    return JSON.parse(readRepoFile("docs/camera-bench.json"));
  } catch {
    return null;
  }
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
