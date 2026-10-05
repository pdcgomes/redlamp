import {
  BarChart,
  Button,
  CollapsibleSection,
  Divider,
  Grid,
  H1,
  H2,
  H3,
  Pill,
  Row,
  Spacer,
  Stack,
  Stat,
  Table,
  Text,
  useCanvasAction,
  useCanvasState,
  useEffect,
  useHostTheme,
  useState,
} from "cursor/canvas";
import type { ChartSeries, SetCanvasState, StatTone } from "cursor/canvas";

// A workstream's canvas (.cursor/skills/workstream-canvas/SKILL.md). Edit only `workstream` below:
// replace every example value, and leave a list empty to hide its section or tab.

type StepStatus = "done" | "in progress" | "not started" | "blocked" | "dropped";

interface Workstream {
  title: string;
  /** What the workstream is for, in a sentence or two. */
  goal: string;
  /** Where it stands now, in a sentence or two. */
  status: string;
  /** When this canvas was last brought up to date (ISO with the time zone), and the last commit it reflects. */
  updated: string;
  lastCommit?: string;
  /** Headline numbers beyond the two the canvas counts itself (steps done, items waiting on the owner). */
  stats: { value: string; label: string; tone?: StatTone }[];
  /**
   * What only the owner can do: say exactly how, and what it unblocks; `blocking` when work waits on it.
   * Once it's done, keep the item: `done: true`, with `detail` starting "Done:" and what came of it.
   */
  needsYou: { id: string; title: string; detail: string; unblocks: string; blocking: boolean; done: boolean; command?: string }[];
  /** Unblocked work the agent can start next. */
  ready: { title: string; detail: string }[];
  /** Work that waits, each naming what it waits on. */
  blocked: { title: string; detail: string; blockedBy: string }[];
  /**
   * The plan's steps, in order: with a plan, one per todo, with the todo's ID (SKILL.md, "A plan's
   * todos are its steps"). `ref`: a tracker ID, an issue (#n) or a commit.
   */
  plan: { id: string; step: string; detail: string; doneWhen: string; status: StepStatus; ref?: string; note?: string }[];
  /** Newest first. Each entry says what happened, what was found and what's queued next. `at`: ISO with the time zone. */
  log: { at: string; text: string }[];
  /** Appended as they happen; a reversed decision is a new row. `by`: Owner, Measured or Default. */
  decisions: { date: string; decision: string; why: string; by: "Owner" | "Measured" | "Default" }[];
  /** Before and after, or any measured comparison: label units and say what it's measured against. */
  measurements: { title: string; caption: string; categories: string[]; series: ChartSeries[]; suffix?: string; horizontal?: boolean }[];
  /** Plans, notes, tracker rows: repository paths or issue links. */
  links: { label: string; target: string }[];
}

const workstream: Workstream = {
  title: "Copy, paste and sync settings",
  goal: "Lightroom's Copy Settings, Paste, Sync and Auto Sync, with a checklist of which settings carry over.",
  status: "All three steps are built and tested; the sheet and the filmstrip's marks still need a look in the app.",
  updated: "2026-10-02T23:00:00+01:00",
  lastCommit: "15e08ae",
  stats: [{ value: "131", label: "UI tests passing" }],
  needsYou: [
    {
      id: "try",
      title: "Try it in the app",
      detail: "The Copy Settings sheet, ⌘- and ⇧-click in the filmstrip, Sync and Auto Sync, on a folder of your own photos.",
      unblocks: "Marking the tracker row Done",
      blocking: true,
      done: false,
      command: "cd ~/src/darkroom && mise run run -- ~/Pictures",
    },
    {
      id: "checklist",
      title: "Choose what the checklist ticks by default",
      detail: "Done: everything but crop and masks, as Lightroom does; the choice is remembered.",
      unblocks: "The Copy Settings sheet",
      blocking: false,
      done: true,
    },
  ],
  ready: [{ title: "Free the worker's engine", detail: "It keeps its models in memory after a batch." }],
  blocked: [],
  plan: [
    {
      id: "model",
      step: "Settings model and merge",
      detail: "Which settings a selection covers, and how a paste merges into an edit.",
      doneWhen: "Every Develop group and mask merges on its own, with tests.",
      status: "done",
      ref: "8c4932f",
    },
    {
      id: "copy",
      step: "Copy Settings checklist, Paste and Previous",
      detail: "The sheet, ⇧⌘C and ⇧⌘V, and Paste from Previous.",
      doneWhen: "Pasting applies only what was ticked, and recomputes pasted AI masks.",
      status: "done",
      ref: "48111e7",
    },
    {
      id: "auto",
      step: "Auto Sync",
      detail: "Every change repeats on the other selected photos.",
      doneWhen: "A slider drag reaches every selected photo once, with Undo.",
      status: "done",
      ref: "15e08ae",
    },
  ],
  log: [
    {
      at: "2026-10-02T23:00:00+01:00",
      text: "Auto Sync landed (15e08ae): a slider drag reaches every selected photo once, as one Undo step. 131 UI tests pass. Next: you try it in the app; the worker's engine keeping its models after a batch is queued.",
    },
  ],
  decisions: [
    {
      date: "2026-10-02",
      decision: "Choose what carries over when copying, as Lightroom does",
      why: "Familiar to Lightroom users; the choice is remembered",
      by: "Owner",
    },
  ],
  measurements: [],
  links: [{ label: "Design", target: "docs/plans/2026-10-02-copy-paste-sync-design.md" }],
};

// ---------------------------------------------------------------- rendering (keys sit on wrapper divs)

const TABS = ["Overview", "Plan", "Decisions", "Log", "Measurements"] as const;
type Tab = (typeof TABS)[number];

const STEP_LABEL: Record<StepStatus, string> = {
  done: "Done",
  "in progress": "In progress",
  "not started": "Not started",
  blocked: "Blocked",
  dropped: "Dropped",
};

type DotState = StepStatus | "waiting" | "blocking";

/**
 * The owner's answers to Needs you, by item ID, kept in the canvas's `.canvas.data.json` under
 * `needsYou`; the agent folds them into `workstream` at its next update (SKILL.md).
 */
type Mark = { state: "done" | "skipped" | "asked"; at: string };
type Marks = Record<string, Mark>;
type SetMarks = SetCanvasState<Marks>;

/** Done or skipped, by the agent's record or the owner's mark. */
function settled(item: Workstream["needsYou"][number], marks: Marks): boolean {
  const state = marks[item.id]?.state;
  return item.done || state === "done" || state === "skipped";
}

function useNow(intervalMs = 30000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(timer);
  }, [intervalMs]);
  return now;
}

function ago(iso: string, now: number): string {
  const ms = now - Date.parse(iso);
  if (Number.isNaN(ms)) return iso;
  const minutes = Math.max(0, Math.round(ms / 60000));
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} h ${minutes % 60} min ago`;
  return `${Math.floor(hours / 24)} d ago`;
}

function when(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return date.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

function Dot({ state }: { state: DotState }) {
  const theme = useHostTheme();
  const color =
    state === "done"
      ? theme.category.green
      : state === "in progress"
        ? theme.accent.primary
        : state === "blocked" || state === "blocking"
          ? theme.category.yellow
          : theme.text.quaternary;
  return <span style={{ display: "inline-block", width: 8, height: 8, borderRadius: 4, background: color, flexShrink: 0 }} />;
}

function CommandBlock({ command }: { command: string }) {
  const theme = useHostTheme();
  return (
    <div
      style={{
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
        fontSize: 11,
        lineHeight: "16px",
        padding: "8px 10px",
        borderRadius: 6,
        background: theme.fill.tertiary,
        color: theme.text.primary,
        wordBreak: "break-word",
        userSelect: "all",
      }}
    >
      {command}
    </div>
  );
}

function NeedsYouItem({
  item,
  mark,
  onMark,
}: {
  item: Workstream["needsYou"][number];
  mark?: Mark;
  onMark: (state: Mark["state"] | null) => void;
}) {
  const dispatch = useCanvasAction();
  const closed = item.done || mark?.state === "done" || mark?.state === "skipped";
  const ask = () => {
    onMark("asked");
    dispatch({
      type: "newComposerChat",
      userPrompt:
        `From this workstream canvas's Needs you list, please take on "${item.title}" (item ${item.id}): ${item.detail}` +
        `${item.command ? ` The command: ${item.command}` : ""} ` +
        "Then update the canvas as .cursor/skills/workstream-canvas/SKILL.md says, with what came of it.",
    });
  };
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "14px minmax(0, 1fr)",
        gap: 8,
        alignItems: "start",
        opacity: closed ? 0.6 : 1,
      }}
    >
      <div style={{ paddingTop: 6 }}>
        <Dot state={closed ? "done" : item.blocking ? "blocking" : "waiting"} />
      </div>
      <Stack gap={3}>
        <Row gap={8} align="center">
          <Text size="small" weight="semibold">
            {item.title}
          </Text>
          {item.blocking && !closed ? <Pill size="sm">Blocks work</Pill> : null}
          {mark?.state === "asked" && !closed ? <Pill size="sm">With an agent</Pill> : null}
        </Row>
        <Text size="small" tone="secondary">
          {item.detail}
        </Text>
        <Text size="small" tone="tertiary">
          {`Unblocks: ${item.unblocks}`}
        </Text>
        {item.command && !closed ? <CommandBlock command={item.command} /> : null}
        {!item.done && mark && mark.state !== "asked" ? (
          <Row gap={8} align="center">
            <Text size="small" tone="tertiary">
              {`${mark.state === "done" ? "Marked done by you" : "Skipped"}, ${when(mark.at)}; the agent picks it up at its next update.`}
            </Text>
            <Button variant="ghost" onClick={() => onMark(null)}>
              Undo
            </Button>
          </Row>
        ) : null}
        {!closed ? (
          <Row gap={6} style={{ paddingTop: 4 }}>
            <Button variant="secondary" onClick={() => onMark("done")}>
              Done
            </Button>
            <Button variant="ghost" onClick={() => onMark("skipped")}>
              Skip
            </Button>
            <Button variant="ghost" onClick={ask}>
              Ask the agent
            </Button>
          </Row>
        ) : null}
      </Stack>
    </div>
  );
}

function NeedsYou({ items, marks, setMarks }: { items: Workstream["needsYou"]; marks: Marks; setMarks: SetMarks }) {
  const markItem = (id: string) => (state: Mark["state"] | null) =>
    setMarks((previous) => {
      const next = { ...previous };
      if (state) next[id] = { state, at: new Date().toISOString() };
      else delete next[id];
      return next;
    });
  const open = items.filter((item) => !settled(item, marks)).sort((a, b) => Number(b.blocking) - Number(a.blocking));
  const done = items.filter((item) => settled(item, marks));
  return (
    <Stack gap={12}>
      <Row gap={8} align="center">
        <H3>Needs you</H3>
        <Spacer />
        <Text size="small" tone="tertiary">
          {`${open.length} open`}
        </Text>
      </Row>
      {open.map((item) => (
        <div key={item.id}>
          <NeedsYouItem item={item} mark={marks[item.id]} onMark={markItem(item.id)} />
        </div>
      ))}
      {done.length > 0 && (
        <CollapsibleSection title="Done" count={done.length} defaultOpen={open.length === 0}>
          <Stack gap={10}>
            {done.map((item) => (
              <div key={item.id}>
                <NeedsYouItem item={item} mark={marks[item.id]} onMark={markItem(item.id)} />
              </div>
            ))}
          </Stack>
        </CollapsibleSection>
      )}
    </Stack>
  );
}

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

function LogEntries({ entries, now }: { entries: Workstream["log"]; now: number }) {
  return (
    <Stack gap={12}>
      {entries.map((entry) => (
        <div
          key={`${entry.at}-${entry.text.slice(0, 32)}`}
          style={{ display: "grid", gridTemplateColumns: "112px minmax(0, 1fr)", gap: 10 }}
        >
          <Stack gap={0}>
            <Text size="small" tone="secondary">
              {ago(entry.at, now)}
            </Text>
            <Text size="small" tone="tertiary">
              {when(entry.at)}
            </Text>
          </Stack>
          <Text size="small">{entry.text}</Text>
        </div>
      ))}
    </Stack>
  );
}

function Progress({ plan }: { plan: Workstream["plan"] }) {
  return (
    <Stack gap={7}>
      {plan.map((step) => (
        <div
          key={step.id}
          style={{
            display: "grid",
            gridTemplateColumns: "14px minmax(0, 1fr) auto",
            gap: 8,
            alignItems: "center",
            opacity: step.status === "dropped" ? 0.5 : 1,
          }}
        >
          <Dot state={step.status} />
          <Text size="small" weight={step.status === "in progress" ? "semibold" : "normal"}>
            {step.step}
          </Text>
          <Text size="small" tone="tertiary">
            {step.ref ?? STEP_LABEL[step.status]}
          </Text>
        </div>
      ))}
    </Stack>
  );
}

function Links({ links }: { links: Workstream["links"] }) {
  return (
    <Stack gap={6}>
      <Divider />
      <Text size="small" tone="secondary">
        {links.map((link) => `${link.label}: ${link.target}`).join(" · ")}
      </Text>
    </Stack>
  );
}

function OverviewTab({ now, marks, setMarks }: { now: number; marks: Marks; setMarks: SetMarks }) {
  const w = workstream;
  const lanes = [
    { title: "Ready", items: w.ready },
    {
      title: "Blocked",
      items: w.blocked.map((item) => ({ title: item.title, detail: `${item.detail} Waits on: ${item.blockedBy}` })),
    },
  ].filter((lane) => lane.items.length > 0);
  const side = w.needsYou.length > 0 || w.log.length > 0;
  return (
    <Grid columns={side ? "minmax(0, 1.5fr) minmax(0, 1fr)" : 1} gap={28} align="start">
      <Stack gap={22}>
        {w.plan.length > 0 && (
          <Stack gap={10}>
            <H2>Progress</H2>
            <Progress plan={w.plan} />
          </Stack>
        )}
        {lanes.length > 0 && (
          <Grid columns={lanes.length} gap={12} align="stretch">
            {lanes.map((lane) => (
              <div key={lane.title} style={{ display: "flex", minWidth: 0 }}>
                <Lane title={lane.title} items={lane.items} />
              </div>
            ))}
          </Grid>
        )}
        {w.links.length > 0 && <Links links={w.links} />}
      </Stack>
      {side && (
        <Stack gap={20}>
          {w.needsYou.length > 0 && <NeedsYou items={w.needsYou} marks={marks} setMarks={setMarks} />}
          {w.needsYou.length > 0 && w.log.length > 0 && <Divider />}
          {w.log.length > 0 && (
            <Stack gap={10}>
              <H3>Latest</H3>
              <LogEntries entries={w.log.slice(0, 4)} now={now} />
            </Stack>
          )}
        </Stack>
      )}
    </Grid>
  );
}

function PlanTab() {
  const theme = useHostTheme();
  return (
    <Stack gap={0}>
      {workstream.plan.map((step, index) => (
        <div
          key={step.id}
          style={{
            display: "grid",
            gridTemplateColumns: "28px minmax(0, 1fr) 150px 116px",
            gap: 12,
            alignItems: "start",
            padding: "10px 0",
            borderTop: index === 0 ? `1px solid ${theme.stroke.tertiary}` : undefined,
            borderBottom: `1px solid ${theme.stroke.tertiary}`,
            opacity: step.status === "done" || step.status === "dropped" ? 0.65 : 1,
          }}
        >
          <Text size="small" tone="tertiary" weight="semibold">
            {`${index + 1}`}
          </Text>
          <Stack gap={2}>
            <Text weight="semibold">{step.step}</Text>
            <Text size="small" tone="secondary">
              {step.detail}
            </Text>
            <Text size="small" tone="tertiary">
              {`Done when: ${step.doneWhen}`}
            </Text>
            {step.note ? <Text size="small">{step.note}</Text> : null}
          </Stack>
          <Text size="small" tone="secondary">
            {step.ref ?? ""}
          </Text>
          <Row gap={6} align="center">
            <Dot state={step.status} />
            <Text size="small" tone="secondary">
              {STEP_LABEL[step.status]}
            </Text>
          </Row>
        </div>
      ))}
    </Stack>
  );
}

function MeasurementsTab() {
  const measurements = workstream.measurements;
  return (
    <Grid columns={Math.min(measurements.length, 2)} gap={24} align="start">
      {measurements.map((m) => (
        <div key={m.title}>
          <Stack gap={6}>
            <Text weight="semibold">{m.title}</Text>
            <BarChart categories={m.categories} series={m.series} valueSuffix={m.suffix} horizontal={m.horizontal} height={260} />
            <Text size="small" tone="tertiary">
              {m.caption}
            </Text>
          </Stack>
        </div>
      ))}
    </Grid>
  );
}

export default function WorkstreamCanvas() {
  const w = workstream;
  const now = useNow();
  const shown: Record<Tab, boolean> = {
    Overview: true,
    Plan: w.plan.length > 0,
    Decisions: w.decisions.length > 0,
    Log: w.log.length > 0,
    Measurements: w.measurements.length > 0,
  };
  const tabs = TABS.filter((tab) => shown[tab]);
  const [selected, setSelected] = useCanvasState<Tab>("tab", "Overview");
  const [marks, setMarks] = useCanvasState<Marks>("needsYou", {});
  const tab: Tab = shown[selected] ? selected : "Overview";
  const live = w.plan.filter((step) => step.status !== "dropped");
  const done = live.filter((step) => step.status === "done").length;
  const open = w.needsYou.filter((item) => !settled(item, marks));
  const blocking = open.filter((item) => item.blocking).length;
  return (
    <Stack gap={18} style={{ padding: 4 }}>
      <Stack gap={6}>
        <H1>{w.title}</H1>
        <Text tone="secondary">{w.goal}</Text>
        <Text>{w.status}</Text>
        <Text size="small" tone="tertiary">
          {`Updated ${ago(w.updated, now)} (${when(w.updated)})${w.lastCommit ? `, up to ${w.lastCommit}` : ""}`}
        </Text>
      </Stack>

      <Row gap={32} wrap>
        {live.length > 0 && (
          <Stat value={`${done} of ${live.length}`} label="Steps done" tone={done === live.length ? "success" : undefined} />
        )}
        {w.needsYou.length > 0 && (
          <Stat
            value={`${open.length}`}
            label={blocking > 0 ? `Waiting on you, ${blocking} blocking` : "Waiting on you"}
            tone={blocking > 0 ? "warning" : undefined}
          />
        )}
        {w.stats.map((stat) => (
          <div key={stat.label}>
            <Stat value={stat.value} label={stat.label} tone={stat.tone} />
          </div>
        ))}
      </Row>

      {tabs.length > 1 && (
        <Row gap={6} wrap>
          {tabs.map((name) => (
            <span key={name}>
              <Pill active={tab === name} onClick={() => setSelected(name)}>
                {name === "Log" ? `Log · ${w.log.length}` : name === "Decisions" ? `Decisions · ${w.decisions.length}` : name}
              </Pill>
            </span>
          ))}
        </Row>
      )}
      <Divider />

      {tab === "Overview" && <OverviewTab now={now} marks={marks} setMarks={setMarks} />}
      {tab === "Plan" && <PlanTab />}
      {tab === "Decisions" && (
        <Table
          headers={["Date", "Decision", "Why", "By"]}
          rows={w.decisions.map((d) => [d.date, d.decision, d.why, d.by])}
          striped
        />
      )}
      {tab === "Log" && <LogEntries entries={w.log} now={now} />}
      {tab === "Measurements" && <MeasurementsTab />}
    </Stack>
  );
}
