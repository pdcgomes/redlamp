import { ComparisonSummary } from "@/components/sections/ComparisonSummary";
import { Inline } from "@/components/ui/Inline";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { type ItemState, itemState, type Phase, phaseNumber, type RoadmapItem, roadmap } from "@/lib/readme";
import { comparison, sourceCommit } from "@/lib/repo";
import { site } from "@/lib/site";
import { phaseCounts, type TrackerRow, trackerRows } from "@/lib/tracker";

const VISIBLE = 4;

function ItemMark({ state }: { state: ItemState | null }) {
  if (state === "done") {
    return (
      <svg viewBox="0 0 16 16" aria-label="Done" className="mt-[3px] size-4 shrink-0 text-paper">
        <circle cx="8" cy="8" r="7.5" fill="currentColor" fillOpacity="0.14" />
        <path d="M5 8.2l2 2 4-4.4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      </svg>
    );
  }
  if (state === "in progress") {
    return (
      <svg viewBox="0 0 16 16" aria-label="In progress" className="mt-[3px] size-4 shrink-0 text-filament">
        <circle cx="8" cy="8" r="6.75" fill="none" stroke="currentColor" />
        <path d="M8 3.5a4.5 4.5 0 0 1 0 9z" fill="currentColor" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 16 16" aria-label={state === "not started" ? "Not started" : undefined} className="mt-[3px] size-4 shrink-0 text-dim">
      <circle cx="8" cy="8" r="6.75" fill="none" stroke="currentColor" strokeDasharray={state === null ? "2 2.2" : undefined} />
    </svg>
  );
}

function PhaseCard({ phase, rows }: { phase: Phase; rows: TrackerRow[] }) {
  const status = (id: string) => rows.find((row) => row.id === id)?.status;
  const stateOf = (item: RoadmapItem) => (item.done === null ? null : itemState(item, status));
  // What's under way leads, so it shows before "Show more"; the rest keeps the README's order.
  const items = [
    ...phase.items.filter((item) => stateOf(item) === "in progress"),
    ...phase.items.filter((item) => stateOf(item) !== "in progress"),
  ];
  const tracked = phase.items.filter((item) => item.done !== null);
  const done = tracked.filter((item) => stateOf(item) === "done").length;
  const inProgress = tracked.filter((item) => stateOf(item) === "in progress").length;
  const number = phaseNumber(phase.title);
  const work = number === null ? null : phaseCounts(rows, number);
  const milestone = `${site.github}/issues?q=${encodeURIComponent(`is:issue milestone:"${phase.title}"`)}`;
  const [title, ...rest] = phase.title.split(": ");
  const subtitle = rest.join(": ");
  const list = (items: Phase["items"]) =>
    items.map((item) => (
      <li key={item.text} className="flex gap-2.5">
        <ItemMark state={stateOf(item)} />
        <span className={item.done ? "text-paper/85" : ""}>
          <Inline md={item.text} />
        </span>
      </li>
    ));

  return (
    <article className="surface flex flex-col p-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="eyebrow">{subtitle ? title : "Unscheduled"}</p>
          <h3 className="font-display mt-1.5 text-[19px] leading-snug">{subtitle || title}</h3>
        </div>
        {phase.status ? (
          <span className="shrink-0 rounded-pill border border-hairline-strong px-2.5 py-1 text-[11.5px] font-medium text-ring">
            {phase.status}
          </span>
        ) : null}
      </div>
      {tracked.length ? (
        <div className="mt-5 flex flex-col gap-2 text-[12px] text-mute">
          <div className="flex items-center gap-3">
            <div className="flex h-1.5 flex-1 overflow-hidden rounded-full bg-paper/8">
              <div className="h-full bg-ring" style={{ width: `${(done / tracked.length) * 100}%` }} />
              <div className="h-full bg-filament/80" style={{ width: `${(inProgress / tracked.length) * 100}%` }} />
            </div>
            {done} of {tracked.length}
            {inProgress ? <span className="text-filament">· {inProgress} under way</span> : null}
          </div>
          {work && work.done + work.inProgress + work.notStarted > 0 ? (
            <a href={milestone} className="text-dim transition-colors hover:text-paper">
              Tracked work: {work.done} done · {work.inProgress} in progress · {work.notStarted} to do
            </a>
          ) : null}
        </div>
      ) : null}
      <ul className="mt-5 flex flex-col gap-2.5 text-[13.5px] leading-relaxed text-mute">{list(items.slice(0, VISIBLE))}</ul>
      {items.length > VISIBLE ? (
        <details className="group mt-2.5">
          <summary className="cursor-pointer list-none text-[13px] font-medium text-ring hover:text-paper">
            <span className="group-open:hidden">Show {items.length - VISIBLE} more</span>
            <span className="hidden group-open:inline">Show fewer</span>
          </summary>
          <ul className="mt-2.5 flex flex-col gap-2.5 text-[13.5px] leading-relaxed text-mute">
            {list(items.slice(VISIBLE))}
          </ul>
        </details>
      ) : null}
    </article>
  );
}

function Legend() {
  return (
    <ul className="mt-8 flex flex-wrap gap-x-6 gap-y-2 text-[13px] text-mute">
      {(["done", "in progress", "not started"] as const).map((state) => (
        <li key={state} className="flex items-center gap-2">
          <ItemMark state={state} />
          <span className="first-letter:uppercase">{state}</span>
        </li>
      ))}
    </ul>
  );
}

export function Roadmap() {
  const { phases } = roadmap();
  const rows = trackerRows();
  const { groups } = comparison();
  const commit = sourceCommit();
  const link = "text-paper underline decoration-hairline-strong underline-offset-3";
  return (
    <section id="roadmap" className="scroll-mt-24 px-6 py-24">
      <div className="mx-auto max-w-6xl">
        <SectionHeading eyebrow="Roadmap" title="Mac first, then iPad and iPhone from the same engine.">
          Phases 1 to 4 build a high-quality editor and engine on macOS; iPad and iPhone follow in Phase 5. This
          roadmap is read from the{" "}
          <a href={`${site.github}#roadmap`} className={link}>
            README
          </a>{" "}
          and the project&apos;s{" "}
          <a href={`${site.github}/blob/main/docs/research/research-tracker.md`} className={link}>
            tracker
          </a>{" "}
          every time the site is built, and each phase links to its work on GitHub.
        </SectionHeading>
        <Legend />
        <div className="mt-8 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {phases.map((phase) => (
            <PhaseCard key={phase.title} phase={phase} rows={rows} />
          ))}
        </div>
        <div className="surface mt-4 flex flex-col gap-5 p-6 sm:flex-row sm:items-center sm:gap-10">
          <div className="sm:w-64 sm:shrink-0">
            <h3 className="font-display text-[19px] leading-snug">Redlamp and Lightroom, feature by feature</h3>
            <a href="/compare" className="mt-2 inline-block text-[13.5px] font-medium text-ring hover:text-paper">
              See how each feature compares
            </a>
          </div>
          <div className="flex-1">
            <ComparisonSummary groups={groups} />
          </div>
        </div>
        {commit ? <p className="mt-4 text-[12px] text-dim">Read at commit {commit}.</p> : null}
      </div>
    </section>
  );
}
