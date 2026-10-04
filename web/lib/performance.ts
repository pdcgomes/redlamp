/**
 * Redlamp's performance history (docs/performance/history.jsonl) and its metrics
 * (docs/performance/metrics.json). A metric got faster or slower when it moved by more than 10%, or
 * by more than its runs' own spread if that's larger, against the previous record from the same
 * source on the same machine; noisy records are drawn but never compared. scripts/perf-history.py
 * applies the same rules. No file access here, so the page's charts can share it; repo.ts reads
 * the files.
 */

export const THRESHOLD = 0.1;

export type Metric = {
  id: string;
  label: string;
  detail: string;
  unit: string;
  group: string;
  better: "lower" | "higher";
  measuredBy: string[];
};
export type Metrics = { groups: string[]; metrics: Metric[] };

export type Entry = { value: number; low?: number; high?: number; spread?: number };
export type RunRecord = {
  date: string;
  commit: string;
  subject?: string;
  dirty?: boolean;
  source: "harness" | "readme";
  machine: { chip?: string; memoryGB?: number; macOS?: string };
  load?: { before: number | null; after: number | null };
  noisy: boolean;
  runs?: number | null;
  note?: string;
  metrics: Record<string, Entry>;
};

export type Point = {
  date: string;
  commit: string;
  subject: string;
  source: RunRecord["source"];
  noisy: boolean;
  chip: string;
  entry: Entry;
};
export type Change = { kind: "faster" | "slower"; ratio: number; from: Point; to: Point };
export type MetricHistory = {
  metric: Metric;
  points: Point[];
  /** The latest point that isn't noisy, else the latest point. */
  current: Point;
  /** The latest point against the previous comparable one, when it moved beyond the noise. */
  change: Change | null;
  /** The first comparable point against the latest, when it moved beyond the noise. */
  sinceFirst: Change | null;
  best: Point;
};

export function parseMetrics(json: string): Metrics {
  const parsed = JSON.parse(json) as { groups?: string[]; metrics?: Metric[] };
  if (!parsed.groups?.length || !parsed.metrics?.length) throw new Error("docs/performance/metrics.json has no groups or metrics");
  for (const metric of parsed.metrics) {
    if (!parsed.groups.includes(metric.group)) {
      throw new Error(`docs/performance/metrics.json: ${metric.id}'s group "${metric.group}" isn't listed in groups`);
    }
  }
  return { groups: parsed.groups, metrics: parsed.metrics };
}

export function parseHistory(jsonl: string, metrics: Metrics): RunRecord[] {
  const known = new Set(metrics.metrics.map((metric) => metric.id));
  return jsonl
    .split("\n")
    .map((line, index) => ({ line: line.trim(), number: index + 1 }))
    .filter(({ line }) => line)
    .map(({ line, number }) => {
      let record: RunRecord;
      try {
        record = JSON.parse(line) as RunRecord;
      } catch {
        throw new Error(`docs/performance/history.jsonl, line ${number}: not JSON`);
      }
      for (const id of Object.keys(record.metrics ?? {})) {
        if (!known.has(id)) throw new Error(`docs/performance/history.jsonl, line ${number}: unknown metric ${id}`);
      }
      return record;
    })
    .sort((a, b) => Date.parse(a.date) - Date.parse(b.date));
}

/** Whether `newer` moved beyond the noise from `older`, and which way. */
export function compare(metric: Metric, older: Point, newer: Point): Change | null {
  const old = older.entry.value;
  if (old <= 0) return null;
  const ratio = (newer.entry.value - old) / old;
  const threshold = Math.max(THRESHOLD, older.entry.spread ?? 0, newer.entry.spread ?? 0);
  if (Math.abs(ratio) <= threshold) return null;
  const worse = metric.better === "lower" ? ratio > 0 : ratio < 0;
  return { kind: worse ? "slower" : "faster", ratio, from: older, to: newer };
}

function comparable(a: Point, b: Point): boolean {
  return a.source === b.source && a.chip === b.chip && !a.noisy && !b.noisy;
}

export function histories(metrics: Metrics, records: RunRecord[]): MetricHistory[] {
  const out: MetricHistory[] = [];
  for (const metric of metrics.metrics) {
    const points: Point[] = records
      .filter((record) => record.metrics[metric.id])
      .map((record) => ({
        date: record.date,
        commit: record.commit,
        subject: record.subject ?? "",
        source: record.source,
        noisy: record.noisy,
        chip: record.machine.chip ?? "",
        entry: record.metrics[metric.id],
      }));
    if (points.length === 0) continue;
    const latest = points[points.length - 1];
    const quiet = points.filter((point) => !point.noisy);
    const current = quiet.at(-1) ?? latest;
    const series = points.filter((point) => comparable(point, current));
    const previous = series.filter((point) => point !== current).at(-1);
    const change = !latest.noisy && previous && current === latest ? compare(metric, previous, current) : null;
    const first = series[0];
    const sinceFirst = first && first !== current ? compare(metric, first, current) : null;
    const ranked = (series.length ? series : [current]).slice();
    const best = ranked.reduce((a, b) =>
      metric.better === "lower" ? (b.entry.value < a.entry.value ? b : a) : b.entry.value > a.entry.value ? b : a,
    );
    out.push({ metric, points, current, change, sinceFirst, best });
  }
  return out;
}

/** The latest harness run, for the page's method section. */
export function latestHarness(records: RunRecord[]): RunRecord | null {
  return records.filter((record) => record.source === "harness").at(-1) ?? null;
}

export function formatValue(value: number, unit: string): string {
  const digits = value >= 100 ? 0 : value >= 10 ? 1 : value >= 1 ? 1 : 2;
  const number = value.toLocaleString("en-GB", { maximumFractionDigits: digits, minimumFractionDigits: 0 });
  if (unit === "%") return `${number}%`;
  if (unit === "/s") return `${number} a second`;
  return `${number} ${unit}`;
}

export function formatEntry(entry: Entry, unit: string): string {
  if (entry.low !== undefined && entry.high !== undefined && entry.low !== entry.high) {
    const low = formatValue(entry.low, unit).replace(` ${unit}`, "");
    return `${low}–${formatValue(entry.high, unit)}`;
  }
  return formatValue(entry.value, unit);
}

/** "58% faster", or "58% less" for memory. */
export function formatChange(change: Change, unit: string): string {
  const percent = Math.round(Math.abs(change.ratio) * 100);
  const memory = unit === "MB" || unit === "GB";
  const word = memory ? (change.kind === "faster" ? "less" : "more") : change.kind;
  return `${percent}% ${word}`;
}
