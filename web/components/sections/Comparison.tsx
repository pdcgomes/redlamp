"use client";

import { useState } from "react";
import { Inline } from "@/components/ui/Inline";
import { StatusMark } from "@/components/ui/StatusMark";
import {
  type ComparisonGroup,
  type ComparisonRow,
  groupId,
  type Status,
  statuses,
  statusStyle,
} from "@/lib/comparison";

export type TrackerLinks = Record<string, { href: string; label: string }>;

function versusLabel(row: ComparisonRow): { label: string; tone: string } | null {
  if (row.status !== "Done") return null;
  if (row.versus === "Behind") return { label: "Behind Lightroom", tone: "text-filament" };
  if (row.versus === "Beyond") return { label: "Beyond Lightroom", tone: "text-ring" };
  if (row.versus === "Different") return { label: "Different approach", tone: "text-mute" };
  if (row.versus === "Compared") return { label: "Compared with Lightroom", tone: "text-ring" };
  if (row.lightroom.has === "No") return { label: "Only in Redlamp", tone: "text-ring" };
  return { label: "Not yet compared", tone: "text-dim" };
}

function Status({ row }: { row: ComparisonRow }) {
  const versus = versusLabel(row);
  return (
    <div className="flex flex-col gap-0.5">
      <span className={`inline-flex items-center gap-2 font-medium ${statusStyle[row.status].text}`}>
        <StatusMark status={row.status} />
        {row.status}
        {row.phase !== null ? <span className="font-normal text-mute">· Phase {row.phase}</span> : null}
      </span>
      {versus ? <span className={`pl-4 text-[12.5px] ${versus.tone}`}>{versus.label}</span> : null}
    </div>
  );
}

function Lightroom({ row }: { row: ComparisonRow }) {
  return (
    <span className={row.lightroom.has === "No" ? "text-dim" : "text-mute"}>
      {row.lightroom.has}
      {row.lightroom.qualifier ? <span className="block text-[12px] text-dim">{row.lightroom.qualifier}</span> : null}
    </span>
  );
}

function Tracker({ ids, links }: { ids: string[]; links: TrackerLinks }) {
  if (ids.length === 0) return null;
  return (
    <span className="flex flex-wrap gap-x-2 gap-y-1">
      {ids.map((id) => (
        <a
          key={id}
          href={links[id]?.href}
          title={`${id} on GitHub`}
          className="font-mono text-[12.5px] text-mute underline decoration-hairline-strong underline-offset-3 hover:text-paper hover:decoration-paper"
        >
          {links[id]?.label ?? id}
        </a>
      ))}
    </span>
  );
}

function GroupProgress({ rows }: { rows: ComparisonRow[] }) {
  const counted = rows.filter((row) => row.status !== "Out of scope");
  if (counted.length === 0) return <span className="text-[12px] text-dim">Out of scope</span>;
  const done = counted.filter((row) => row.status === "Done").length;
  const inProgress = counted.filter((row) => row.status === "In progress").length;
  return (
    <span className="flex items-center gap-3 text-[12px] text-mute">
      <span className="flex h-1.5 w-28 overflow-hidden rounded-full bg-paper/8">
        <span className="h-full bg-ring" style={{ width: `${(done / counted.length) * 100}%` }} />
        <span className="h-full bg-filament/80" style={{ width: `${(inProgress / counted.length) * 100}%` }} />
      </span>
      {done} of {counted.length} done
    </span>
  );
}

export function Comparison({ groups, links }: { groups: ComparisonGroup[]; links: TrackerLinks }) {
  const [status, setStatus] = useState<Status | "All">("All");
  const [onlyRedlamp, setOnlyRedlamp] = useState(false);
  const [query, setQuery] = useState("");
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const matches = (row: ComparisonRow, group: string) =>
    (status === "All" || row.status === status) &&
    (!onlyRedlamp || row.lightroom.has === "No") &&
    words.every((word) => `${row.feature} ${row.notes} ${group} ${row.tracker.join(" ")}`.toLowerCase().includes(word));
  const visible = groups
    .map((group) => ({ ...group, shown: group.rows.filter((row) => matches(row, group.title)) }))
    .filter((group) => group.shown.length > 0);
  const shownCount = visible.reduce((sum, group) => sum + group.shown.length, 0);

  return (
    <div className="grid gap-10 lg:grid-cols-[190px_1fr]">
      <nav aria-label="Groups" className="hidden lg:block">
        <ul className="sticky top-28 flex flex-col gap-1.5 text-[13px]">
          {groups.map((group) => (
            <li key={group.title}>
              <a href={`#${groupId(group.title)}`} className="text-mute transition-colors hover:text-paper">
                {group.title}
              </a>
            </li>
          ))}
        </ul>
      </nav>

      <div className="flex min-w-0 flex-col gap-8">
        <div className="flex flex-col gap-4">
          <div role="group" aria-label="Filter by status" className="flex flex-wrap gap-2">
            {(["All", ...statuses] as const).map((option) => {
              const active = option === status;
              return (
                <button
                  key={option}
                  aria-pressed={active}
                  onClick={() => setStatus(option)}
                  className={`inline-flex items-center gap-2 rounded-pill px-3.5 py-1.5 text-[13px] font-medium transition-colors ${
                    active ? "bg-paper text-ink" : "button-secondary text-mute hover:text-paper"
                  }`}
                >
                  {option === "All" ? null : <StatusMark status={option} />}
                  {option}
                </button>
              );
            })}
            <button
              aria-pressed={onlyRedlamp}
              onClick={() => setOnlyRedlamp(!onlyRedlamp)}
              className={`rounded-pill px-3.5 py-1.5 text-[13px] font-medium transition-colors ${
                onlyRedlamp ? "bg-paper text-ink" : "button-secondary text-mute hover:text-paper"
              }`}
            >
              Only in Redlamp
            </button>
          </div>
          <div className="flex flex-wrap items-center gap-4">
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search features, such as masks or denoise"
              aria-label="Search features"
              className="w-full max-w-sm rounded-pill border border-hairline-strong bg-paper/5 px-4 py-2 text-[14px] text-paper placeholder:text-dim focus:outline-none focus-visible:border-ring"
            />
            <p aria-live="polite" className="text-[13px] text-dim">
              {shownCount} {shownCount === 1 ? "feature" : "features"}
            </p>
          </div>
        </div>

        {visible.length === 0 ? (
          <p className="text-[15px] text-mute">Nothing matches. Try another word, or show all statuses.</p>
        ) : null}

        {visible.map((group) => (
          <section key={group.title} id={groupId(group.title)} aria-labelledby={`${groupId(group.title)}-title`} className="scroll-mt-28">
            <div className="mb-3 flex flex-wrap items-end justify-between gap-3">
              <h2 id={`${groupId(group.title)}-title`} className="font-display text-[20px] leading-snug">
                {group.title}
              </h2>
              <GroupProgress rows={group.rows} />
            </div>
            <div className="surface overflow-hidden">
              <table className="w-full border-collapse text-left text-[14px]">
                <thead className="hidden text-[11px] tracking-[0.12em] text-dim uppercase md:table-header-group">
                  <tr className="border-b border-hairline">
                    <th className="py-3 pr-3 pl-5 font-semibold">Feature</th>
                    <th className="w-28 px-3 py-3 font-semibold">Lightroom</th>
                    <th className="w-56 px-3 py-3 font-semibold">Redlamp</th>
                    <th className="w-36 py-3 pr-5 pl-3 font-semibold">On GitHub</th>
                  </tr>
                </thead>
                <tbody>
                  {group.shown.map((row) => (
                    <tr key={row.feature} className="border-b border-hairline align-top last:border-b-0">
                      <td className="py-3.5 pr-3 pl-5">
                        <p className="font-medium text-paper">{row.feature}</p>
                        {row.notes ? (
                          <p className="mt-1 text-[13px] leading-relaxed text-mute">
                            <Inline md={row.notes} />
                          </p>
                        ) : null}
                        <div className="mt-2.5 flex flex-col gap-2 text-[13px] md:hidden">
                          <Status row={row} />
                          <span className="text-dim">
                            Lightroom: <Lightroom row={row} />
                          </span>
                          <Tracker ids={row.tracker} links={links} />
                        </div>
                      </td>
                      <td className="hidden px-3 py-3.5 md:table-cell">
                        <Lightroom row={row} />
                      </td>
                      <td className="hidden px-3 py-3.5 md:table-cell">
                        <Status row={row} />
                      </td>
                      <td className="hidden py-3.5 pr-5 pl-3 md:table-cell">
                        <Tracker ids={row.tracker} links={links} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        ))}
      </div>
    </div>
  );
}
