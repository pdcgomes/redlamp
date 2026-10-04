import { readRepoFile } from "./repo.ts";
import { tableRows } from "./tables.ts";

/**
 * The research tracker (docs/research/research-tracker.md), read the way scripts/tracker-issues.py reads
 * it: the same statuses and the same phase for each row, so the roadmap's counts match the milestones the
 * sync files issues under.
 */

export type TrackerStatus = "done" | "in progress" | "blocked" | "not needed" | "not started";
export type TrackerRow = {
  id: string;
  item: string;
  section: string;
  phase: number | null;
  status: TrackerStatus;
  rejected: boolean;
};

const ID = /^(?:[A-Z]{2,4}|P1)-\d+$/;
const STATUSES: TrackerStatus[] = ["done", "in progress", "blocked", "not needed", "not started"];

function statusOf(text: string): TrackerStatus {
  const lower = text.toLowerCase();
  return STATUSES.find((status) => lower.startsWith(status)) ?? "not started";
}

export function parseTracker(markdown: string): TrackerRow[] {
  const raw = tableRows(markdown, "ID").filter((row) => ID.test(row.cells.ID));
  const byId = new Map(raw.map((row) => [row.cells.ID, row]));
  const phaseOf = (row: (typeof raw)[number], seen: Set<string>): number | null => {
    const { ID: id, Phase: phase } = row.cells;
    if (id.startsWith("P1-") || (row.section.startsWith("2. Phase 1") && phase === undefined)) return 1;
    const number = phase?.match(/P(\d)/);
    if (number) return Number(number[1]);
    const other = phase?.match(/^With ((?:[A-Z]{2,4}|P1)-\d+)/)?.[1];
    if (other && byId.has(other) && !seen.has(other)) return phaseOf(byId.get(other)!, new Set([...seen, id]));
    return phase?.startsWith("Now") ? 1 : null;
  };
  return raw.map((row) => ({
    id: row.cells.ID,
    item: row.cells.Item ?? row.cells.Question ?? row.cells.Skip ?? "",
    section: row.section,
    phase: phaseOf(row, new Set()),
    status: statusOf(row.cells.Status ?? ""),
    rejected: (row.cells.Decision ?? "").startsWith("Rejected"),
  }));
}

let cached: TrackerRow[] | null = null;

export function trackerRows(): TrackerRow[] {
  cached ??= parseTracker(readRepoFile("docs/research/research-tracker.md"));
  return cached;
}

export type WorkCounts = { done: number; inProgress: number; notStarted: number };

/**
 * The work rows of one phase by status, leaving out decisions, recorded skips and work that turned out
 * not to be needed (or was rejected). Blocked work counts as not started.
 */
export function phaseCounts(rows: TrackerRow[], phase: number): WorkCounts {
  const counts: WorkCounts = { done: 0, inProgress: 0, notStarted: 0 };
  for (const row of rows) {
    if (row.phase !== phase || /^(DEC|SKIP)-/.test(row.id) || row.status === "not needed" || row.rejected) continue;
    if (row.status === "done") counts.done += 1;
    else if (row.status === "in progress") counts.inProgress += 1;
    else counts.notStarted += 1;
  }
  return counts;
}

export type Issue = { number: number; title: string; body?: string | null; pull_request?: unknown };

/** Tracker IDs to issue numbers, as the sync recognises its issues: the body's marker, else the title's prefix. */
export function issueNumbers(issues: Issue[]): Map<string, number> {
  const numbers = new Map<string, number>();
  for (const issue of issues) {
    if (issue.pull_request) continue;
    const marker = issue.body?.match(/<!-- tracker-id: (\S+) -->/)?.[1];
    const titled = issue.title.match(/^\[?((?:[A-Z]{2,4}|P1)-\d+)\]?[:\s]/)?.[1];
    const id = marker ?? titled;
    if (id && !numbers.has(id)) numbers.set(id, issue.number);
  }
  return numbers;
}

/** A tracker row's link: its issue when it has one, else a search for its ID among the issues. */
export function trackerLink(id: string, numbers: Map<string, number>, github: string): { href: string; label: string } {
  const number = numbers.get(id);
  if (number !== undefined) return { href: `${github}/issues/${number}`, label: `#${number}` };
  return { href: `${github}/issues?q=${encodeURIComponent(`is:issue "${id}"`)}`, label: id };
}
