import { readRepoFile } from "./repo.ts";

/**
 * The README is the project's status page, so the roadmap and the list of what works today are read from
 * it at build time rather than copied: every push that updates the README updates the site. Item text
 * stays Markdown; `<Inline>` renders it. Roadmap items name their tracker rows in a trailing comment
 * (`<!-- tracker: TON-06 -->`, or `<!-- internal -->`), which is read here and left out of the text.
 */

export type RoadmapItem = {
  text: string;
  /** Ticked, unticked, or null for the unscheduled "Later" list. */
  done: boolean | null;
  tracker: string[];
  internal: boolean;
};
export type Phase = { title: string; status: string | null; items: RoadmapItem[] };
export type FeatureGroup = { title: string; items: string[] };

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
      const tag = top[2].match(/<!--(.*?)-->/)?.[1] ?? "";
      items.push({
        text: top[2].replace(/\s*<!--.*?-->/g, "").trim(),
        done: top[1] === undefined ? null : top[1] === "x",
        tracker: tag.match(/\b(?:[A-Z]{2,4}|P1)-\d+\b/g) ?? [],
        internal: /\binternal\b/.test(tag),
      });
      continue;
    }
    const nested = line.match(/^\s+- (.*)$/);
    if (nested && items.length > 0) items[items.length - 1].text += ` ${nested[1].trim()}`;
  }
  return items;
}

export function parseRoadmap(markdown: string): { intro: string; phases: Phase[] } {
  const body = section(markdown, "## Roadmap");
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

export function parseWorksToday(markdown: string): FeatureGroup[] {
  const body = section(markdown, "### What works today");
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

export type ItemState = "done" | "in progress" | "not started";

/** Ticked is done; unticked with one of its tracker rows started (or finished) is in progress. */
export function itemState(item: RoadmapItem, status: (id: string) => string | undefined): ItemState {
  if (item.done) return "done";
  const started = item.tracker.some((id) => ["done", "in progress"].includes(status(id) ?? ""));
  return started ? "in progress" : "not started";
}

/** The number of a "Phase N: Title" heading, or null for Later and other sections. */
export function phaseNumber(title: string): number | null {
  const found = title.match(/^Phase (\d+):/);
  return found ? Number(found[1]) : null;
}

export function roadmap(): { intro: string; phases: Phase[] } {
  return parseRoadmap(readRepoFile("README.md"));
}

export function worksToday(): FeatureGroup[] {
  return parseWorksToday(readRepoFile("README.md"));
}

export function lastUpdated(): string | null {
  return readRepoFile("README.md").match(/Last updated: ([^.*]+)/)?.[1].trim() ?? null;
}
