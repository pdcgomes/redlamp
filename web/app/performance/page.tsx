import type { Metadata } from "next";
import { BarChart } from "@/components/charts/BarChart";
import { LineChart } from "@/components/charts/LineChart";
import {
  type Change,
  formatChange,
  formatEntry,
  histories,
  latestHarness,
  type MetricHistory,
  type Point,
  THRESHOLD,
} from "@/lib/performance";
import { performance, sourceCommit } from "@/lib/repo";
import { site } from "@/lib/site";

const title = "How fast Redlamp is, measured";
const description =
  "Redlamp's performance over time: opening, editing, exporting, detail, memory and the main thread, measured on an Apple M1 Ultra, with what's getting faster and what's getting slower.";

export const metadata: Metadata = {
  title: "Performance",
  description,
  alternates: { canonical: "/performance" },
  openGraph: { type: "website", siteName: site.name, title, description, url: "/performance", locale: "en_GB" },
  twitter: { card: "summary_large_image", title, description },
};

const HEADLINE = ["open", "render-fit", "render-full", "export-full", "drag-p95", "folders-list"];
const FRAME_BARS = ["render-fit-masks", "render-fit", "detail-view-amount", "detail-view-luminance", "detail-view-radius", "detail-view-sharpen", "render-full"];
const link = "text-paper underline decoration-hairline-strong underline-offset-3 hover:decoration-paper";

function date(point: Point): string {
  return new Date(point.date).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
}

function provenance(point: Point): string {
  const where = point.source === "readme" ? "the README" : "a harness run";
  return `${where}, ${date(point)}${point.noisy ? ", under load" : ""}`;
}

function commitLink(point: Point) {
  return (
    <a href={`${site.github}/commit/${point.commit}`} className="font-mono text-[12px] text-mute underline decoration-hairline underline-offset-3 hover:text-paper">
      {point.commit}
    </a>
  );
}

function Moved({ history, change }: { history: MetricHistory; change: Change }) {
  const { metric } = history;
  return (
    <li className="flex flex-col gap-1 border-b border-hairline py-3.5 last:border-b-0">
      <div className="flex flex-wrap items-baseline justify-between gap-x-3">
        <span className="font-medium text-paper">{metric.label}</span>
        <span className={`text-[13px] font-medium ${change.kind === "faster" ? "text-ring" : "text-filament"}`}>
          {formatChange(change, metric.unit)}
        </span>
      </div>
      <p className="text-[13px] text-mute">
        {formatEntry(change.from.entry, metric.unit)} on {date(change.from)}, {formatEntry(change.to.entry, metric.unit)} on {date(change.to)}
      </p>
      {change.to.subject ? (
        <p className="text-[12.5px] text-dim">
          {commitLink(change.to)} {change.to.subject}
        </p>
      ) : null}
    </li>
  );
}

function MetricCard({ history }: { history: MetricHistory }) {
  const { metric, points, current, change } = history;
  return (
    <article className="surface flex flex-col gap-3 p-5">
      <div>
        <h3 className="text-[14.5px] font-medium text-paper">{metric.label}</h3>
        <p className="mt-0.5 text-[12.5px] text-dim">{metric.detail}</p>
      </div>
      <p className="font-display text-[26px] leading-none text-paper">{formatEntry(current.entry, metric.unit)}</p>
      {points.length > 1 ? (
        <LineChart metric={metric} points={points} />
      ) : (
        <p className="text-[12.5px] text-dim">One measurement so far.</p>
      )}
      <p className="text-[12px] text-dim">
        From {provenance(current)}
        {change ? `; ${formatChange(change, metric.unit)} than the record before` : ""}.
      </p>
    </article>
  );
}

export default function PerformancePage() {
  const { metrics, records } = performance();
  const all = histories(metrics, records);
  const byId = new Map(all.map((history) => [history.metric.id, history]));
  const headline = HEADLINE.map((id) => byId.get(id)).filter((history) => history !== undefined);
  const faster = all.filter((history) => history.sinceFirst?.kind === "faster").sort((a, b) => a.sinceFirst!.ratio - b.sinceFirst!.ratio);
  const slower = all.filter((history) => history.sinceFirst?.kind === "slower").sort((a, b) => b.sinceFirst!.ratio - a.sinceFirst!.ratio);
  const bars = FRAME_BARS.map((id) => byId.get(id))
    .filter((history) => history !== undefined)
    .map((history) => ({ label: history.metric.label, value: history.current.entry.value }));
  const harness = latestHarness(records);
  const commit = sourceCommit();
  const readmeRecords = records.filter((record) => record.source === "readme");
  return (
    <section className="px-6 pt-16 pb-24">
      <div className="mx-auto max-w-6xl">
        <div className="max-w-3xl">
          <p className="eyebrow">Performance</p>
          <h1 className="font-display mt-3 text-[clamp(2.2rem,5vw,3.4rem)] leading-[1.05] text-paper">{title}</h1>
          <p className="mt-5 text-[17px] leading-relaxed text-mute">
            Redlamp is built to answer every slider within a frame. These are its measurements over time, on an Apple M1
            Ultra with a Release build: the figures the README recorded as the work landed, and the runs its benchmark
            harness records now. A metric counts as faster or slower only when it moves by more than{" "}
            {Math.round(THRESHOLD * 100)}%, or by more than its runs&apos; own spread.
          </p>
        </div>

        <dl className="surface mt-10 grid gap-x-8 gap-y-7 p-6 sm:grid-cols-2 sm:p-8 lg:grid-cols-3">
          {headline.map((history) => (
            <div key={history.metric.id} className="flex flex-col-reverse">
              <dt className="mt-2 text-[14px] text-mute">
                {history.metric.label}
                <span className="block text-[12px] text-dim">From {provenance(history.current)}</span>
              </dt>
              <dd className="font-display text-[clamp(1.9rem,3.6vw,2.4rem)] leading-none text-paper">
                {formatEntry(history.current.entry, history.metric.unit)}
              </dd>
            </div>
          ))}
        </dl>

        <div className="mt-16 grid gap-10 lg:grid-cols-[1fr_1.1fr]">
          <div>
            <h2 className="font-display text-[24px] leading-snug">Against a display&apos;s frame</h2>
            <p className="mt-3 text-[15px] leading-relaxed text-mute">
              What a slider costs while you drag it, and the whole photo at 1:1, beside one frame of a 120 Hz and a 60 Hz
              display.
            </p>
          </div>
          <BarChart bars={bars} />
        </div>

        {faster.length || slower.length ? (
          <div className="mt-16">
            <h2 className="font-display text-[24px] leading-snug">What&apos;s moved since it was first measured</h2>
            <p className="mt-3 max-w-3xl text-[15px] leading-relaxed text-mute">
              Each metric&apos;s latest figure against its first, from the same source on the same machine. Some work makes
              a step slower on purpose, for better results; the change that did it is named beside each.
            </p>
            <div className="mt-6 grid gap-6 lg:grid-cols-2">
              {[
                { heading: "Getting faster", items: faster },
                { heading: "Getting slower", items: slower },
              ]
                .filter((column) => column.items.length > 0)
                .map((column) => (
                  <div key={column.heading} className="surface px-5 py-2">
                    <h3 className="pt-3 text-[12px] font-semibold tracking-[0.14em] text-mute uppercase">{column.heading}</h3>
                    <ul>
                      {column.items.map((history) => (
                        <Moved key={history.metric.id} history={history} change={history.sinceFirst!} />
                      ))}
                    </ul>
                  </div>
                ))}
            </div>
          </div>
        ) : null}

        <div className="mt-16">
          <h2 className="font-display text-[24px] leading-snug">Every metric over time</h2>
          <ul className="mt-3 flex flex-wrap gap-x-6 gap-y-2 text-[13px] text-mute">
            <li className="flex items-center gap-2">
              <span aria-hidden className="inline-block size-2.5 rounded-full border-[1.5px] border-ring" /> As recorded in the README
            </li>
            <li className="flex items-center gap-2">
              <span aria-hidden className="inline-block size-2.5 rounded-full bg-paper" /> A harness run
            </li>
            <li className="flex items-center gap-2">
              <span aria-hidden className="inline-block size-2.5 rounded-full border-[1.5px] border-dashed border-ring opacity-50" />{" "}
              Measured under load (drawn, never compared)
            </li>
            <li className="flex items-center gap-2">
              <span aria-hidden className="inline-block h-3 w-px bg-mute" /> A range: the README&apos;s, or the fastest to slowest sample file
            </li>
          </ul>
          {metrics.groups.map((group) => {
            const inGroup = all.filter((history) => history.metric.group === group);
            return inGroup.length ? (
              <section key={group} aria-labelledby={`group-${group}`} className="mt-10">
                <h3 id={`group-${group}`} className="eyebrow">
                  {group}
                </h3>
                <div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                  {inGroup.map((history) => (
                    <MetricCard key={history.metric.id} history={history} />
                  ))}
                </div>
              </section>
            ) : null;
          })}
        </div>

        <div className="surface mt-16 flex flex-col gap-4 p-6 sm:p-8">
          <h2 className="font-display text-[20px] leading-snug">How it&apos;s measured</h2>
          <ul className="flex max-w-3xl list-disc flex-col gap-2 pl-5 text-[14.5px] leading-relaxed text-mute marker:text-dim">
            <li>
              <code className="font-mono text-[0.9em] text-ring">scripts/perf-record.sh</code> builds Release and runs{" "}
              <code className="font-mono text-[0.9em] text-ring">redlamp bench</code> on the CC0 sample raws from{" "}
              <a href={site.rawPixls} className={link}>
                raw.pixls.us
              </a>{" "}
              (each measurement repeated after a warm-up; a metric is the median across the files), then drags a slider at
              120 events a second with every panel open, and opens 50,000 photos in 500 folders.
            </li>
            <li>
              Runs recorded while the Mac was busy (a load average above 8) are kept and drawn but never compared, and the
              figures the README recorded ({readmeRecords.length} versions from{" "}
              {readmeRecords[0] ? new Date(readmeRecords[0].date).toLocaleDateString("en-GB", { day: "numeric", month: "long" }) : "its start"}) are
              compared only with each other: they were measured by hand, some as ranges.
            </li>
            {harness ? (
              <li>
                The latest harness run: {new Date(harness.date).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })}, commit{" "}
                <a href={`${site.github}/commit/${harness.commit}`} className={link}>
                  {harness.commit}
                </a>
                , {harness.machine.chip}
                {harness.machine.memoryGB ? ` with ${harness.machine.memoryGB} GB` : ""}, macOS {harness.machine.macOS}, {harness.runs} runs per
                measurement, load average {harness.load?.before ?? "unknown"} before and {harness.load?.after ?? "unknown"} after
                {harness.noisy ? ", so it's recorded as noisy" : ""}.
              </li>
            ) : null}
            <li>No Lightroom figures: Redlamp hasn&apos;t measured Lightroom on the same photos.</li>
          </ul>
          <p className="text-[12.5px] text-dim">
            Read from{" "}
            <a href={`${site.github}/blob/main/docs/performance/history.jsonl`} className="underline decoration-hairline-strong underline-offset-3 hover:text-mute">
              docs/performance/history.jsonl
            </a>
            {commit ? ` at commit ${commit}` : ""}.
          </p>
        </div>
      </div>
    </section>
  );
}
