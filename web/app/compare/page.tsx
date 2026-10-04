import type { Metadata } from "next";
import { Comparison, type TrackerLinks } from "@/components/sections/Comparison";
import { ComparisonSummary } from "@/components/sections/ComparisonSummary";
import { Inline } from "@/components/ui/Inline";
import { trackerIssues } from "@/lib/github";
import { comparison, sourceCommit } from "@/lib/repo";
import { site } from "@/lib/site";
import { trackerLink } from "@/lib/tracker";

const title = "Redlamp and Lightroom, feature by feature";
const description =
  "What works in Redlamp today, what's being built, what's planned and what's left out, set against the Lightroom features photographers know.";

export const metadata: Metadata = {
  title: "Compare with Lightroom",
  description,
  alternates: { canonical: "/compare" },
  openGraph: { type: "website", siteName: site.name, title, description, url: "/compare", locale: "en_GB" },
  twitter: { card: "summary_large_image", title, description },
};

const legend: [string, string][] = [
  ["Done", "works in the app today."],
  ["In progress", "being built."],
  ["Planned", "on the roadmap, in the phase shown."],
  ["Later", "after 1.0."],
  ["Undecided", "Lightroom has it; Redlamp hasn't decided yet."],
  ["Out of scope", "left out, with the reason."],
  ["Not yet compared", "works, but its results haven't been checked against Lightroom's side by side."],
  ["Behind, Beyond or Different", "a known gap, more than Lightroom does, or a different approach by design."],
];

export default async function ComparePage() {
  const { groups, checkedAgainst } = comparison();
  const numbers = await trackerIssues();
  const links: TrackerLinks = Object.fromEntries(
    groups.flatMap((group) => group.rows.flatMap((row) => row.tracker)).map((id) => [id, trackerLink(id, numbers, site.github)]),
  );
  const commit = sourceCommit();
  const source = `${site.github}/blob/main/docs/lightroom-comparison.md`;
  return (
    <section className="px-6 pt-16 pb-24">
      <div className="mx-auto max-w-6xl">
        <div className="max-w-3xl">
          <p className="eyebrow">Compare</p>
          <h1 className="font-display mt-3 text-[clamp(2.2rem,5vw,3.4rem)] leading-[1.05] text-paper">{title}</h1>
          <p className="mt-5 text-[17px] leading-relaxed text-mute">
            The Lightroom features photographers know, and where Redlamp stands on each. Redlamp is in pre-alpha, so much
            of the list is still ahead; each row says plainly what works, what&apos;s being built and what isn&apos;t
            coming. Features that work haven&apos;t yet been compared with Lightroom&apos;s results unless a row says so.
          </p>
        </div>

        <div className="surface mt-10 flex flex-col gap-6 p-6 sm:p-8">
          <ComparisonSummary groups={groups} />
          <dl className="grid gap-x-8 gap-y-1.5 border-t border-hairline pt-5 text-[13px] leading-relaxed sm:grid-cols-2">
            {legend.map(([term, meaning]) => (
              <div key={term}>
                <dt className="inline font-semibold text-paper">{term}:</dt> <dd className="inline text-mute">{meaning}</dd>
              </div>
            ))}
          </dl>
          <p className="text-[12.5px] leading-relaxed text-dim">
            {checkedAgainst ? (
              <>
                Lightroom checked against: <Inline md={checkedAgainst} />{" "}
              </>
            ) : null}
            Read from{" "}
            <a href={source} className="underline decoration-hairline-strong underline-offset-3 hover:text-mute">
              docs/lightroom-comparison.md
            </a>
            {commit ? ` at commit ${commit}` : null}, which follows the project&apos;s tracker; each row links to its GitHub
            issue, where the work can be followed and discussed.
          </p>
        </div>

        <div className="mt-14">
          <Comparison groups={groups} links={links} />
        </div>
      </div>
    </section>
  );
}
