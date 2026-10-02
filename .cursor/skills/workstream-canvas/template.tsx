import { BarChart, Divider, Grid, H1, H2, Row, Stack, Stat, Table, Text, useHostTheme } from "cursor/canvas";
import type { ChartSeries, StatTone, TableRowTone } from "cursor/canvas";

// A workstream's canvas (.cursor/skills/workstream-canvas/SKILL.md). Edit only `workstream` below:
// replace every example value, and leave a list empty to hide its section.

type StepStatus = "done" | "in progress" | "not started" | "blocked" | "dropped";

interface Workstream {
  title: string;
  /** What the workstream is for, in a sentence. */
  goal: string;
  /** Where it stands now, in a sentence or two. */
  status: string;
  /** The day this canvas was last brought up to date, and the last commit it reflects. */
  updated: string;
  lastCommit?: string;
  /** Two to four headline numbers. */
  stats: { value: string; label: string; tone?: StatTone }[];
  next: {
    /** Only the owner can do these: decisions, photos, measurements, trying things in the app. */
    needsOwner: { title: string; detail: string }[];
    /** Unblocked work the agent can start. */
    ready: { title: string; detail: string }[];
    /** Each with what blocks it (a DEC- row, an SDK, data). */
    blocked: { title: string; detail: string }[];
  };
  /** The plan's steps, in order. `ref`: a tracker ID, issue (#n) or commit. */
  plan: { step: string; status: StepStatus; note?: string; ref?: string }[];
  /** Before and after, or any measured comparison: label units and say what it's measured against. */
  measurements: { title: string; caption: string; categories: string[]; series: ChartSeries[]; suffix?: string; horizontal?: boolean }[];
  /** Appended as they happen; a reversed decision is a new row. `by`: Owner, Measured or Default. */
  decisions: { date: string; decision: string; why: string; by: "Owner" | "Measured" | "Default" }[];
  /** Newest first. */
  timeline: { commit: string; date: string; summary: string }[];
  /** Plans, notes, tracker rows: repository paths or issue links. */
  links: { label: string; target: string }[];
}

const workstream: Workstream = {
  title: "Copy, paste and sync settings",
  goal: "Lightroom's Copy Settings, Paste, Sync and Auto Sync, with a checklist of which settings carry over.",
  status: "All five steps are built and tested; the sheet and the filmstrip's marks still need a look in the app.",
  updated: "2026-10-02",
  lastCommit: "c46706a",
  stats: [
    { value: "5 of 5", label: "Steps built", tone: "success" },
    { value: "131", label: "UI tests passing" },
  ],
  next: {
    needsOwner: [{ title: "Try it in the app", detail: "The Copy Settings sheet, ⌘- and ⇧-click in the filmstrip, Sync and Auto Sync." }],
    ready: [{ title: "Free the worker's engine", detail: "It keeps its models in memory after a batch." }],
    blocked: [],
  },
  plan: [
    { step: "Settings model and merge", status: "done", ref: "8c4932f" },
    { step: "Copy Settings checklist, Paste and Previous", status: "done", ref: "48111e7" },
    { step: "Filmstrip multi-selection", status: "done", ref: "32774fc" },
    { step: "Sync across a selection, with Undo", status: "done", ref: "2adcdf9" },
    { step: "Auto Sync", status: "done", ref: "15e08ae" },
  ],
  measurements: [],
  decisions: [
    {
      date: "2026-10-02",
      decision: "Choose what carries over when copying, as Lightroom does",
      why: "Familiar to Lightroom users; the choice is remembered",
      by: "Owner",
    },
  ],
  timeline: [{ commit: "15e08ae", date: "2026-10-02", summary: "Auto Sync" }],
  links: [{ label: "Design", target: "docs/plans/2026-10-02-copy-paste-sync-design.md" }],
};

// ---------------------------------------------------------------- rendering (keys sit on wrapper divs)

const stepTone: Record<StepStatus, TableRowTone> = {
  done: "success",
  "in progress": "info",
  "not started": "neutral",
  blocked: "danger",
  dropped: "neutral",
};

function Lane({ title, items }: { title: string; items: { title: string; detail: string }[] }) {
  const theme = useHostTheme();
  return (
    <Stack gap={10} style={{ padding: 14, background: theme.fill.quaternary, borderRadius: 8, minWidth: 0 }}>
      <Row justify="space-between" align="center">
        <Text weight="semibold">{title}</Text>
        <Text size="small" tone="tertiary">
          {`${items.length}`}
        </Text>
      </Row>
      {items.map((item) => (
        <div key={item.title}>
          <Stack gap={2}>
            <Text size="small" weight="medium">
              {item.title}
            </Text>
            <Text size="small" tone="secondary">
              {item.detail}
            </Text>
          </Stack>
        </div>
      ))}
    </Stack>
  );
}

export default function WorkstreamCanvas() {
  const w = workstream;
  const lanes = [
    { title: "Needs you", items: w.next.needsOwner },
    { title: "Ready to start", items: w.next.ready },
    { title: "Blocked", items: w.next.blocked },
  ].filter((lane) => lane.items.length > 0);
  const done = w.plan.filter((step) => step.status === "done").length;
  return (
    <Stack gap={24} style={{ padding: 4 }}>
      <Stack gap={6}>
        <H1>{w.title}</H1>
        <Text tone="secondary">{w.goal}</Text>
        <Text>{w.status}</Text>
        <Text size="small" tone="tertiary">
          {`Updated ${w.updated}${w.lastCommit ? `, up to ${w.lastCommit}` : ""}${
            w.plan.length > 0 ? ` · ${done} of ${w.plan.length} steps done` : ""
          }`}
        </Text>
      </Stack>

      {w.stats.length > 0 && (
        <Row gap={32} wrap>
          {w.stats.map((stat) => (
            <div key={stat.label}>
              <Stat value={stat.value} label={stat.label} tone={stat.tone} />
            </div>
          ))}
        </Row>
      )}

      {lanes.length > 0 && (
        <Stack gap={10}>
          <H2>What's next</H2>
          <Grid columns={lanes.length} gap={12} align="stretch">
            {lanes.map((lane) => (
              <div key={lane.title} style={{ display: "flex", minWidth: 0 }}>
                <Lane title={lane.title} items={lane.items} />
              </div>
            ))}
          </Grid>
        </Stack>
      )}

      {w.plan.length > 0 && (
        <Stack gap={8}>
          <H2>Plan</H2>
          <Table
            headers={["Step", "Status", "Notes", "Ref"]}
            rows={w.plan.map((step) => [step.step, step.status, step.note ?? "", step.ref ?? ""])}
            rowTone={w.plan.map((step) => stepTone[step.status])}
          />
        </Stack>
      )}

      {w.measurements.length > 0 && (
        <Stack gap={8}>
          <H2>Measurements</H2>
          <Grid columns={Math.min(w.measurements.length, 2)} gap={24} align="start">
            {w.measurements.map((m) => (
              <div key={m.title}>
                <Stack gap={6}>
                  <Text weight="semibold">{m.title}</Text>
                  <BarChart
                    categories={m.categories}
                    series={m.series}
                    valueSuffix={m.suffix}
                    horizontal={m.horizontal}
                    height={260}
                  />
                  <Text size="small" tone="tertiary">
                    {m.caption}
                  </Text>
                </Stack>
              </div>
            ))}
          </Grid>
        </Stack>
      )}

      {w.decisions.length > 0 && (
        <Stack gap={8}>
          <H2>Decisions</H2>
          <Table
            headers={["Date", "Decision", "Why", "By"]}
            rows={w.decisions.map((d) => [d.date, d.decision, d.why, d.by])}
            striped
          />
        </Stack>
      )}

      {w.timeline.length > 0 && (
        <Stack gap={8}>
          <H2>Timeline</H2>
          <Table
            headers={["Commit", "Date", "What landed"]}
            rows={w.timeline.map((t) => [t.commit, t.date, t.summary])}
            framed={false}
          />
        </Stack>
      )}

      {w.links.length > 0 && (
        <Stack gap={6}>
          <Divider />
          <Text size="small" tone="secondary">
            {w.links.map((link) => `${link.label}: ${link.target}`).join(" · ")}
          </Text>
        </Stack>
      )}
    </Stack>
  );
}
