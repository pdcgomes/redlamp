import { readFileSync } from "node:fs";
import path from "node:path";

/**
 * The README is the project's status page, so the roadmap and the list of what works
 * today are read from it at build time rather than copied: every push that updates the
 * README updates the site. Item text stays Markdown; `<Inline>` renders it.
 */

export type RoadmapItem = { text: string; done: boolean | null };
export type Phase = { title: string; status: string | null; items: RoadmapItem[] };
export type FeatureGroup = { title: string; items: string[] };

let cached: string | null = null;

function readme(): string {
  cached ??= readFileSync(path.join(process.cwd(), "..", "README.md"), "utf8");
  return cached;
}

/** The body under `heading` (matched by prefix), up to the next heading of the same or a higher level. */
function section(markdown: string, heading: string): string {
  const level = heading.match(/^#+/)?.[0].length ?? 2;
  const lines = markdown.split("\n");
  const start = lines.findIndex((line) => line.startsWith(heading));
  if (start < 0) throw new Error(`README: no "${heading}" section`);
  const body: string[] = [];
  for (const line of lines.slice(start + 1)) {
    const match = line.match(/^(#+) /);
    if (match && match[1].length <= level) break;
    body.push(line);
  }
  return body.join("\n");
}

function bulletItems(lines: string[]): RoadmapItem[] {
  const items: RoadmapItem[] = [];
  for (const line of lines) {
    const top = line.match(/^- (?:\[( |x)\] )?(.*)$/);
    if (top) {
      items.push({ text: top[2].trim(), done: top[1] === undefined ? null : top[1] === "x" });
      continue;
    }
    const nested = line.match(/^\s+- (.*)$/);
    if (nested && items.length > 0) items[items.length - 1].text += ` ${nested[1].trim()}`;
  }
  return items;
}

export function roadmap(): { intro: string; phases: Phase[] } {
  const body = section(readme(), "## Roadmap");
  const [introPart, ...parts] = body.split(/^### /m);
  const phases = parts
    .map((part) => {
      const [headingLine, ...rest] = part.split("\n");
      const status = headingLine.match(/\*\((.+)\)\*/)?.[1] ?? null;
      const title = headingLine.replace(/\*\(.+\)\*/, "").trim();
      return { title, status, items: bulletItems(rest) };
    })
    .filter((phase) => phase.items.length > 0);
  return { intro: introPart.trim(), phases };
}

export function worksToday(): FeatureGroup[] {
  const body = section(readme(), "### What works today");
  const groups: FeatureGroup[] = [];
  let current: FeatureGroup | null = null;
  let pending: string[] = [];
  const flush = () => {
    if (current) current.items.push(...bulletItems(pending).map((item) => item.text));
    pending = [];
  };
  for (const line of body.split("\n")) {
    const header = line.match(/^\*\*(.+?)\*\*(.*)$/);
    if (header) {
      flush();
      const note = header[2].trim();
      current = { title: note ? `${header[1]} ${note}` : header[1], items: [] };
      groups.push(current);
    } else {
      pending.push(line);
    }
  }
  flush();
  return groups.filter((group) => group.items.length > 0);
}

export function lastUpdated(): string | null {
  return readme().match(/Last updated: ([^.*]+)/)?.[1].trim() ?? null;
}
