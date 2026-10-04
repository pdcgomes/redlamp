import Image from "next/image";
import type { ReactNode } from "react";
import { Inline } from "@/components/ui/Inline";
import { LightboxGroup, ShotButton } from "@/components/ui/Lightbox";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { type Feature, features, focusStacking } from "@/content/features";
import { formatEntry, histories } from "@/lib/performance";
import { lastUpdated, worksToday } from "@/lib/readme";
import { performance } from "@/lib/repo";

const featureShots = features.flatMap((feature) => (feature.shot ? [feature.shot] : []));

function Check() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="mt-[3px] size-4 shrink-0 text-ring">
      <circle cx="8" cy="8" r="7.25" fill="none" stroke="currentColor" strokeOpacity="0.35" />
      <path d="M5 8.2l2 2 4-4.4" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}

/** A claim on one side and the screen that backs it up on the other, alternating down the page. */
function FlowSection({ feature, reverse, media }: { feature: Feature; reverse: boolean; media: ReactNode }) {
  return (
    <div
      id={feature.id}
      className={`flex scroll-mt-28 flex-col items-center gap-10 lg:gap-16 ${reverse ? "lg:flex-row-reverse" : "lg:flex-row"}`}
    >
      <div className="lg:w-[38%]">
        <p className="eyebrow">{feature.eyebrow}</p>
        <h3 className="font-display mt-3 text-[clamp(1.6rem,3vw,2.2rem)] leading-[1.12]">{feature.title}</h3>
        {feature.body.map((paragraph) => (
          <p key={paragraph} className="mt-4 text-[16px] leading-relaxed text-mute">
            {paragraph}
          </p>
        ))}
        <ul className="mt-6 flex flex-col gap-2.5 text-[14.5px] text-paper/90">
          {feature.points.map((point) => (
            <li key={point} className="flex gap-2.5">
              <Check />
              <span>{point}</span>
            </li>
          ))}
        </ul>
      </div>
      <div className="w-full lg:w-[62%]">{media}</div>
    </div>
  );
}

function StackIllustration() {
  const frames = [0, 1, 2, 3, 4];
  return (
    <div className="surface relative flex aspect-[16/10] items-center justify-center overflow-hidden">
      <div aria-hidden className="absolute inset-0 bg-[radial-gradient(50%_60%_at_50%_45%,rgb(224_64_46/0.16),transparent_70%)]" />
      <svg viewBox="0 0 400 250" className="relative w-[78%]" aria-label="Five frames focused at different depths merging into one sharp photo">
        {frames.map((i) => (
          <g key={i} transform={`translate(${40 + i * 22} ${30 + i * 14})`} opacity={0.35 + i * 0.13}>
            <rect width="190" height="126" rx="8" fill="#1c1615" stroke="rgba(243,238,232,0.22)" />
            <circle cx={40 + i * 28} cy="70" r="16" fill="none" stroke="#d9d0cb" strokeOpacity={i === 4 ? 0.9 : 0.35} strokeWidth="2" />
            <rect x="18" y="104" width="154" height="8" rx="4" fill="rgba(243,238,232,0.08)" />
            <rect x="18" y="104" width={34 + i * 30} height="8" rx="4" fill="#d9d0cb" fillOpacity="0.45" />
          </g>
        ))}
        <path d="M300 92 L340 92" stroke="#d9d0cb" strokeOpacity="0.5" strokeWidth="2" strokeLinecap="round" />
        <path d="M332 85 L341 92 L332 99" fill="none" stroke="#d9d0cb" strokeOpacity="0.5" strokeWidth="2" strokeLinecap="round" />
        <g transform="translate(300 120)">
          <rect width="84" height="56" rx="6" fill="#262019" stroke="rgba(243,238,232,0.4)" />
          {[18, 34, 50, 66].map((x) => (
            <circle key={x} cx={x} cy="26" r="7" fill="none" stroke="#f3eee8" strokeWidth="1.6" />
          ))}
        </g>
      </svg>
    </div>
  );
}

function Shot({ feature }: { feature: Feature }) {
  if (!feature.shot) return null;
  return (
    <figure>
      <ShotButton index={featureShots.indexOf(feature.shot)} label={feature.shot.alt}>
        <Image
          src={feature.shot.src}
          alt={feature.shot.alt}
          width={feature.shot.width}
          height={feature.shot.height}
          sizes="(min-width: 1024px) 700px, 94vw"
          className="shot h-auto w-full"
        />
      </ShotButton>
      <figcaption className="mt-3 text-[13px] text-dim">{feature.shot.caption}</figcaption>
    </figure>
  );
}

export function Features() {
  return (
    <section id="features" className="scroll-mt-24 px-6 py-24">
      <div className="mx-auto max-w-6xl">
        <SectionHeading eyebrow="What works today" title="A complete Develop module, built for Apple Silicon.">
          The core RAW pipeline and the Develop workspace work today on macOS 26. Every screenshot here is the app
          itself, on CC0 sample raws.
        </SectionHeading>
        <LightboxGroup shots={featureShots}>
          <div className="mt-20 flex flex-col gap-28">
            {features.map((feature, index) => (
              <FlowSection key={feature.id} feature={feature} reverse={index % 2 === 1} media={<Shot feature={feature} />} />
            ))}
            <FlowSection
              feature={{ id: "focus-stacking", ...focusStacking, body: [focusStacking.body] }}
              reverse={features.length % 2 === 1}
              media={<StackIllustration />}
            />
          </div>
        </LightboxGroup>
      </div>
    </section>
  );
}

const STRIP = ["open", "render-fit", "render-full", "export-full"];

export function Performance() {
  const { metrics, records } = performance();
  const byId = new Map(histories(metrics, records).map((history) => [history.metric.id, history]));
  const shown = STRIP.map((id) => byId.get(id)).filter((history) => history !== undefined);
  return (
    <section aria-label="Measured performance" className="px-6 pb-24">
      <div className="surface mx-auto max-w-6xl px-6 py-10 sm:px-10">
        <dl className="grid gap-8 sm:grid-cols-2 lg:grid-cols-4">
          {shown.map((history) => (
            <div key={history.metric.id}>
              <dt className="sr-only">{history.metric.label}</dt>
              <dd className="font-display text-[clamp(2rem,4vw,2.6rem)] leading-none text-paper">
                {formatEntry(history.current.entry, history.metric.unit)}
              </dd>
              <dd className="mt-2 text-[14px] text-mute">{history.metric.label}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-8 text-[12.5px] text-dim">
          Measured on an Apple M1 Ultra with a Release build.{" "}
          <a href="/performance" className="text-ring underline decoration-hairline-strong underline-offset-3 hover:text-paper">
            Every measurement, and how it has changed
          </a>
        </p>
      </div>
    </section>
  );
}

export function EverythingToday() {
  const groups = worksToday();
  const updated = lastUpdated();
  return (
    <section aria-labelledby="everything" className="px-6 pb-24">
      <div className="mx-auto max-w-6xl">
        <div className="flex flex-wrap items-end justify-between gap-4">
          <h3 id="everything" className="font-display text-[22px]">
            Everything that works today
          </h3>
          {updated ? <p className="text-[13px] text-dim">From the README, last updated {updated}.</p> : null}
        </div>
        <div className="mt-6 grid gap-3 lg:grid-cols-2">
          {groups.map((group) => (
            <details key={group.title} className="surface group px-5 py-4 open:pb-5">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-4 text-[15px] font-semibold text-paper">
                <span>{group.title}</span>
                <span className="flex items-center gap-3 text-[12px] font-medium text-mute">
                  {group.items.length} items
                  <svg viewBox="0 0 12 12" aria-hidden className="size-3 transition-transform group-open:rotate-180">
                    <path d="M2.5 4.5L6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
                  </svg>
                </span>
              </summary>
              <ul className="mt-4 flex flex-col gap-2.5 text-[14px] leading-relaxed text-mute">
                {group.items.map((item) => (
                  <li key={item} className="flex gap-2.5">
                    <Check />
                    <span>
                      <Inline md={item} />
                    </span>
                  </li>
                ))}
              </ul>
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}
