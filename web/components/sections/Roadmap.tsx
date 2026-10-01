import { Inline } from "@/components/ui/Inline";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { type Phase, roadmap } from "@/lib/readme";
import { site } from "@/lib/site";

const VISIBLE = 4;

function ItemMark({ done }: { done: boolean | null }) {
  if (done) {
    return (
      <svg viewBox="0 0 16 16" aria-label="Done" className="mt-[3px] size-4 shrink-0 text-paper">
        <circle cx="8" cy="8" r="7.5" fill="currentColor" fillOpacity="0.14" />
        <path d="M5 8.2l2 2 4-4.4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 16 16" aria-label={done === false ? "Not done yet" : undefined} className="mt-[3px] size-4 shrink-0 text-dim">
      <circle cx="8" cy="8" r="6.75" fill="none" stroke="currentColor" strokeDasharray={done === null ? "2 2.2" : undefined} />
    </svg>
  );
}

function PhaseCard({ phase }: { phase: Phase }) {
  const tracked = phase.items.filter((item) => item.done !== null);
  const done = tracked.filter((item) => item.done).length;
  const progress = tracked.length ? done / tracked.length : 0;
  const [title, ...rest] = phase.title.split(": ");
  const subtitle = rest.join(": ");
  const list = (items: Phase["items"]) =>
    items.map((item) => (
      <li key={item.text} className="flex gap-2.5">
        <ItemMark done={item.done} />
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
        <div className="mt-5 flex items-center gap-3 text-[12px] text-mute">
          <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-paper/8">
            <div className="h-full rounded-full bg-ring" style={{ width: `${Math.round(progress * 100)}%` }} />
          </div>
          {done} of {tracked.length}
        </div>
      ) : null}
      <ul className="mt-5 flex flex-col gap-2.5 text-[13.5px] leading-relaxed text-mute">{list(phase.items.slice(0, VISIBLE))}</ul>
      {phase.items.length > VISIBLE ? (
        <details className="group mt-2.5">
          <summary className="cursor-pointer list-none text-[13px] font-medium text-ring hover:text-paper">
            <span className="group-open:hidden">Show {phase.items.length - VISIBLE} more</span>
            <span className="hidden group-open:inline">Show fewer</span>
          </summary>
          <ul className="mt-2.5 flex flex-col gap-2.5 text-[13.5px] leading-relaxed text-mute">
            {list(phase.items.slice(VISIBLE))}
          </ul>
        </details>
      ) : null}
    </article>
  );
}

export function Roadmap() {
  const { phases } = roadmap();
  return (
    <section id="roadmap" className="scroll-mt-24 px-6 py-24">
      <div className="mx-auto max-w-6xl">
        <SectionHeading eyebrow="Roadmap" title="Mac first, then iPad and iPhone from the same engine.">
          Phases 1 to 4 build a high-quality editor and engine on macOS; iPad and iPhone follow in Phase 5. This
          roadmap is read from the{" "}
          <a href={`${site.github}#roadmap`} className="text-paper underline decoration-hairline-strong underline-offset-3">
            README
          </a>{" "}
          every time the site is built.
        </SectionHeading>
        <div className="mt-14 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {phases.map((phase) => (
            <PhaseCard key={phase.title} phase={phase} />
          ))}
        </div>
      </div>
    </section>
  );
}
