import { tableRows } from "./tables.ts";

/**
 * Redlamp and Lightroom compared (docs/lightroom-comparison.md): a table per group of features. A row
 * that breaks the document's vocabulary fails the build, naming its line; whether the rows agree with
 * the tracker is scripts/roadmap-sync.py's job, so a disagreement never stops a deploy. No file access
 * here, so the page's client component can share it; `comparison()` in repo.ts reads the file.
 */

export const statuses = ["Done", "In progress", "Planned", "Later", "Undecided", "Out of scope"] as const;
export type Status = (typeof statuses)[number];
export const versusLabels = ["Compared", "Behind", "Beyond", "Different"] as const;
export type Versus = (typeof versusLabels)[number];

export type ComparisonRow = {
  feature: string;
  lightroom: { has: "Yes" | "Partly" | "No"; qualifier: string | null };
  status: Status;
  /** Only on Done rows; null there means not yet compared (or only in Redlamp, when Lightroom has no such feature). */
  versus: Versus | null;
  phase: number | null;
  tracker: string[];
  /** Inline Markdown. */
  notes: string;
};

export type ComparisonGroup = { title: string; rows: ComparisonRow[] };
export type Comparison = { checkedAgainst: string | null; groups: ComparisonGroup[] };

const COLUMNS = ["Feature", "Lightroom", "Redlamp", "vs Lightroom", "Phase", "Tracker", "Notes"];

export function parseComparison(markdown: string): Comparison {
  const groups: ComparisonGroup[] = [];
  for (const { section, line, cells } of tableRows(markdown, "Feature")) {
    const fail = (message: string): never => {
      throw new Error(`docs/lightroom-comparison.md, line ${line} (${cells.Feature}): ${message}`);
    };
    if (Object.keys(cells).join("|") !== COLUMNS.join("|")) fail(`the table's columns must be ${COLUMNS.join(", ")}`);
    const lightroom = cells.Lightroom.match(/^(Yes|Partly|No)\b\s*(?:\((.+)\))?$/);
    if (!lightroom) fail("Lightroom must be Yes, Partly or No, with an optional qualifier in brackets");
    const status = cells.Redlamp as Status;
    if (!statuses.includes(status)) fail(`Redlamp must be one of ${statuses.join(", ")}`);
    const versus = (cells["vs Lightroom"] || null) as Versus | null;
    if (versus && !versusLabels.includes(versus)) fail(`vs Lightroom must be blank or one of ${versusLabels.join(", ")}`);
    if (versus && status !== "Done") fail("vs Lightroom is only for Done rows");
    const phase = cells.Phase ? Number(cells.Phase.match(/^P(\d)$/)?.[1] ?? Number.NaN) : null;
    if (phase !== null && Number.isNaN(phase)) fail("Phase must be P0 to P9");
    if (status === "Planned" && phase === null) fail("a Planned row needs its Phase");
    if (phase !== null && status !== "Planned" && status !== "In progress") fail("only Planned and In progress rows have a Phase");
    let group = groups.at(-1);
    if (group?.title !== section) {
      group = { title: section, rows: [] };
      groups.push(group);
    }
    group.rows.push({
      feature: cells.Feature,
      lightroom: { has: lightroom![1] as ComparisonRow["lightroom"]["has"], qualifier: lightroom![2] ?? null },
      status,
      versus,
      phase,
      tracker: cells.Tracker.split(",").map((id) => id.trim()).filter(Boolean),
      notes: cells.Notes,
    });
  }
  if (groups.length === 0) throw new Error("docs/lightroom-comparison.md has no comparison tables");
  const checkedAgainst = markdown.match(/^\*\*Lightroom checked against:\*\*\s*(.+)$/m)?.[1].trim() ?? null;
  return { checkedAgainst, groups };
}

/** Each status's mark and its share of a progress bar, the same everywhere the site shows it. */
export const statusStyle: Record<Status, { text: string; dot: string; bar: string }> = {
  Done: { text: "text-paper", dot: "bg-ring", bar: "bg-ring" },
  "In progress": { text: "text-filament", dot: "bg-filament", bar: "bg-filament/80" },
  Planned: { text: "text-ring", dot: "border border-ring", bar: "bg-ring/30" },
  Later: { text: "text-mute", dot: "border border-dashed border-mute", bar: "bg-paper/12" },
  Undecided: { text: "text-mute", dot: "border border-dotted border-dim", bar: "bg-paper/9" },
  "Out of scope": { text: "text-dim", dot: "bg-dim/50", bar: "bg-paper/6" },
};

/** A group's anchor on the page. */
export function groupId(title: string): string {
  return title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

export function statusCounts(groups: ComparisonGroup[]): Record<Status, number> {
  const counts = Object.fromEntries(statuses.map((status) => [status, 0])) as Record<Status, number>;
  for (const row of groups.flatMap((group) => group.rows)) counts[row.status] += 1;
  return counts;
}
