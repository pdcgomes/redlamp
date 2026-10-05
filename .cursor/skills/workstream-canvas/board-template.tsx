import {
  BarChart,
  Button,
  Card,
  CardBody,
  CardHeader,
  CollapsibleSection,
  Divider,
  Grid,
  H1,
  H2,
  H3,
  Link,
  Pill,
  Row,
  Spacer,
  Stack,
  Swatch,
  Table,
  Text,
  UsageBar,
  useCanvasAction,
  useCanvasState,
  useEffect,
  useHostTheme,
  useState,
} from "cursor/canvas";
import type { ChartSeries, Color, SetCanvasState } from "cursor/canvas";

// A workstream board (.cursor/skills/workstream-canvas/SKILL.md, "Boards"): for a feature with
// milestones, each made of tracker rows. Edit the data at the top (BOARD, MILESTONES, LATER, NOW,
// AGENTS, DOCS and `workstream`) and leave the rendering below alone.

const BOARD = {
  title: "Example feature",
  lede: "One line on what the feature is, and where it's built (~/src/project on feature/example).",
  /** What the overall bar covers: the rows of every milestone in MILESTONES. */
  scope: "The release",
  checkout: "/path/to/your/checkout",
  issues: "https://github.com/owner/repository/issues",
};

// ---------------------------------------------------------------- milestones and their rows

/**
 * done: merged where it ships, and its "done when" met.
 * built: merged and tested; a measurement at scale or a small part is still to do (the note says what).
 * doing: being built now. you: waiting on the owner. todo: not started.
 */
type RowState = "done" | "built" | "doing" | "you" | "todo";
type BoardRow = { id: string; issue: number; title: string; state: RowState; note: string };
type MilestoneStatus = "active" | "next" | "later" | "done";
type Milestone = { id: string; name: string; status: MilestoneStatus; doneWhen: string; rows: BoardRow[] };

const row = (id: string, issue: number, title: string, state: RowState, note: string): BoardRow => ({
  id,
  issue,
  title,
  state,
  note,
});

const MILESTONES: Milestone[] = [
  {
    id: "M1",
    name: "Foundation",
    status: "active",
    doneWhen: "What must be true, and measured, for the milestone to be done.",
    rows: [
      row("FEAT-01", 101, "A row that's done", "done", "Merged (abc1234), and its done-when is met."),
      row("FEAT-02", 102, "A row that's built", "built", "Merged and tested; its check at full scale is left."),
      row("FEAT-03", 103, "A row being built", "doing", "What the agent is building, in a line."),
      row("FEAT-04", 104, "A row waiting on you", "you", "Waits on a decision only you can make."),
    ],
  },
  {
    id: "M2",
    name: "The next milestone",
    status: "next",
    doneWhen: "Its done-when, from the plan.",
    rows: [row("FEAT-05", 105, "A row not started", "todo", "What it will do.")],
  },
];

const LATER: Milestone = {
  id: "Later",
  name: "After the release",
  status: "later",
  doneWhen: "After the release.",
  rows: [row("FEAT-06", 106, "A row for later", "todo", "Why it waits.")],
};

// ---------------------------------------------------------------- now

const NOW = {
  task: "What's being built now (FEAT-03, #103)",
  detail: "Who is building it and where, and what has landed so far, with commits and test counts.",
  waiting: "What's waiting on you, or that nothing blocks work.",
  next: "What comes next, in order.",
};

/** Agent conversations: `id` is the conversation's UUID, so Open can go to it. */
const AGENTS: { title: string; row: string; ended: string; id: string }[] = [
  { title: "The agent building FEAT-03", row: "FEAT-03", ended: "Running", id: "conversation-uuid" },
];

const DOCS = [{ label: "Plan", path: `${BOARD.checkout}/docs/plans/feature-plan.md` }];

// ---------------------------------------------------------------- the workstream record

type StepStatus = "done" | "in progress" | "not started" | "blocked" | "dropped";

interface Workstream {
  updated: string;
  lastCommit: string;
  /** What only the owner can do; done items keep `done: true` and a detail starting "Done:". */
  needsYou: { id: string; title: string; detail: string; unblocks: string; blocking: boolean; done: boolean; command?: string }[];
  /** The plan's todos, one step each, with the todo's ID. */
  plan: { id: string; step: string; doneWhen: string; status: StepStatus; ref?: string; note?: string }[];
  /** Newest first. */
  log: { at: string; text: string }[];
  decisions: { date: string; decision: string; why: string; by: "Owner" | "Measured" | "Default" }[];
  measurements: {
    title: string;
    caption: string;
    categories: string[];
    series: ChartSeries[];
    suffix?: string;
    horizontal?: boolean;
    budget?: { value: number; label: string };
  }[];
  /** Key figures that aren't one chart: measure, result, budget or context. */
  figures: { title: string; caption: string; rows: [string, string, string][] }[];
}

const workstream: Workstream = {
  updated: "2026-10-05T18:00:00+01:00",
  lastCommit: "abc1234",
  needsYou: [
    {
      id: "example",
      title: "Something only you can do",
      detail: "Exactly how to do it, written so it can be done without opening the transcript.",
      unblocks: "What it unblocks",
      blocking: true,
      done: false,
      command: "the shell line to copy",
    },
  ],
  plan: [{ id: "first-todo", step: "The plan's first todo", doneWhen: "Its done-when.", status: "in progress", ref: "FEAT-01" }],
  log: [
    {
      at: "2026-10-05T18:00:00+01:00",
      text: "What happened, what was found and what's queued next, naming commits, counts and blockers.",
    },
  ],
  decisions: [{ date: "2026-10-05", decision: "A decision", why: "Why it was made", by: "Owner" }],
  measurements: [
    {
      title: "A measurement against its budget",
      caption: "What was measured, where, when, and how busy the machine was.",
      categories: ["Run 1", "Run 2"],
      series: [{ name: "Milliseconds", data: [12, 9], tone: "info" }],
      suffix: " ms",
      budget: { value: 16, label: "Budget 16 ms" },
    },
  ],
  figures: [{ title: "Key figures", caption: "Where they come from.", rows: [["A measure", "Its result", "Its budget or context"]] }],
};

// ---------------------------------------------------------------- helpers

const STATE: Record<RowState, { label: string; color: Color }> = {
  done: { label: "Done", color: "green" },
  built: { label: "Built", color: "cyan" },
  doing: { label: "In progress", color: "blue" },
  you: { label: "Waiting on you", color: "yellow" },
  todo: { label: "Not started", color: "gray" },
};

const MILESTONE_STATUS: Record<MilestoneStatus, { label: string; color: Color }> = {
  active: { label: "In progress", color: "blue" },
  next: { label: "Next", color: "gray" },
  later: { label: "Later", color: "gray" },
  done: { label: "Done", color: "green" },
};

const STEP_COLOR: Record<StepStatus, Color> = {
  done: "green",
  "in progress": "blue",
  "not started": "gray",
  blocked: "yellow",
  dropped: "gray",
};

const count = (rows: readonly BoardRow[], state: RowState) => rows.filter((r) => r.state === state).length;
const builtOrDone = (rows: readonly BoardRow[]) => count(rows, "done") + count(rows, "built");
const percent = (rows: readonly BoardRow[]) => Math.round((builtOrDone(rows) / Math.max(rows.length, 1)) * 100);

type Mark = { state: "done" | "skipped" | "asked"; at: string };
type Marks = Record<string, Mark>;
type SetMarks = SetCanvasState<Marks>;

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

// ---------------------------------------------------------------- pieces

function Dot({ color }: { color: Color }) {
  return <Swatch color={color} style={{ width: 10, height: 10, borderRadius: 3, flexShrink: 0 }} />;
}

function StatusTag({ label, color }: { label: string; color: Color }) {
  return (
    <Row gap={6} align="center">
      <Dot color={color} />
      <Text size="small" tone="secondary">
        {label}
      </Text>
    </Row>
  );
}

function Progress({ rows, label }: { rows: readonly BoardRow[]; label?: string }) {
  const parts = [
    `${count(rows, "done")} done`,
    `${count(rows, "built")} built`,
    `${count(rows, "doing")} in progress`,
    `${count(rows, "todo") + count(rows, "you")} to go`,
  ];
  return (
    <UsageBar
      total={rows.length}
      topLeftLabel={label ?? `${percent(rows)}% built`}
      topRightLabel={`${parts.join(" · ")} of ${rows.length}`}
      segments={(
        [
          { id: "done", value: count(rows, "done"), color: "green" },
          { id: "built", value: count(rows, "built"), color: "cyan" },
          { id: "doing", value: count(rows, "doing"), color: "blue" },
          { id: "you", value: count(rows, "you"), color: "yellow" },
        ] as { id: string; value: number; color: Color }[]
      ).filter((segment) => segment.value > 0)}
    />
  );
}

function Legend() {
  const keys: [Color, string, string][] = [
    ["green", "Done", "merged and its done-when met"],
    ["cyan", "Built", "merged and tested; a check at scale or a small part left"],
    ["blue", "In progress", "being built now"],
    ["yellow", "Waiting on you", ""],
  ];
  return (
    <Row gap={16} wrap>
      {keys.map(([color, label, hint]) => (
        <div key={label} style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <Dot color={color} />
          <Text size="small" tone="secondary">
            {label}
          </Text>
          {hint ? (
            <Text size="small" tone="tertiary">
              {hint}
            </Text>
          ) : null}
        </div>
      ))}
      <Text size="small" tone="tertiary">
        Empty: not started
      </Text>
    </Row>
  );
}

function MilestoneTile({ m }: { m: Milestone }) {
  const theme = useHostTheme();
  const status = MILESTONE_STATUS[m.status];
  return (
    <div
      style={{
        border: `1px solid ${theme.stroke.tertiary}`,
        background: m.status === "active" ? theme.fill.tertiary : undefined,
        borderRadius: 8,
        padding: 12,
      }}
    >
      <Stack gap={8}>
        <Row gap={8} align="start" justify="space-between">
          <Stack gap={2}>
            <Text size="small" tone="tertiary" weight="semibold">
              {m.id}
            </Text>
            <Text weight="semibold">{m.name}</Text>
          </Stack>
          <StatusTag label={status.label} color={status.color} />
        </Row>
        <Progress rows={m.rows} />
      </Stack>
    </div>
  );
}

function Roadmap() {
  const core = MILESTONES.flatMap((m) => m.rows);
  return (
    <Stack gap={14}>
      <Stack gap={6}>
        <Progress rows={core} label={`${BOARD.scope}: ${percent(core)}% built (${builtOrDone(core)} of ${core.length} rows)`} />
        <Legend />
      </Stack>
      <Grid columns="repeat(3, minmax(0, 1fr))" gap={12} align="stretch">
        {MILESTONES.map((m) => (
          <div key={m.id} style={{ display: "flex", flexDirection: "column", minWidth: 0 }}>
            <MilestoneTile m={m} />
          </div>
        ))}
      </Grid>
      <Text size="small" tone="tertiary">
        {`${LATER.name}: ${LATER.rows.length} rows, ${builtOrDone(LATER.rows)} built.`}
      </Text>
    </Stack>
  );
}

function NowPanel() {
  const theme = useHostTheme();
  const dispatch = useCanvasAction();
  return (
    <div style={{ background: theme.fill.tertiary, borderRadius: 8, padding: 16 }}>
      <Stack gap={12}>
        <Stack gap={4}>
          <Text size="small" weight="semibold" style={{ color: theme.accent.primary }}>
            Now
          </Text>
          <H3>{NOW.task}</H3>
          <Text tone="secondary">{NOW.detail}</Text>
        </Stack>
        <Grid columns={2} gap={16}>
          <Stack gap={2}>
            <Text size="small" tone="tertiary">
              Waiting on you
            </Text>
            <Text>{NOW.waiting}</Text>
          </Stack>
          <Stack gap={2}>
            <Text size="small" tone="tertiary">
              Next
            </Text>
            <Text>{NOW.next}</Text>
          </Stack>
        </Grid>
        <Row gap={8} wrap>
          {DOCS.map((d) => (
            <span key={d.label}>
              <Button variant="secondary" onClick={() => dispatch({ type: "openFile", path: d.path })}>
                {d.label}
              </Button>
            </span>
          ))}
        </Row>
      </Stack>
    </div>
  );
}

function RowLine({ row }: { row: BoardRow }) {
  const state = STATE[row.state];
  return (
    <div style={{ display: "grid", gridTemplateColumns: "14px 64px minmax(0, 1fr) 112px", gap: 10, alignItems: "start" }}>
      <div style={{ paddingTop: 4 }}>
        <Dot color={state.color} />
      </div>
      <Link href={`${BOARD.issues}/${row.issue}`}>{`${row.id} #${row.issue}`}</Link>
      <Stack gap={2}>
        <Text size="small" weight="semibold">
          {row.title}
        </Text>
        <Text size="small" tone="secondary">
          {row.note}
        </Text>
      </Stack>
      <Text size="small" tone="tertiary">
        {state.label}
      </Text>
    </div>
  );
}

function MilestoneDetail({ m, open }: { m: Milestone; open: boolean }) {
  const status = MILESTONE_STATUS[m.status];
  return (
    <CollapsibleSection
      title={`${m.id} · ${m.name}`}
      leading={<Dot color={status.color} />}
      trailing={`${builtOrDone(m.rows)} of ${m.rows.length} built`}
      defaultOpen={open}
    >
      <Stack gap={10} style={{ paddingTop: 4 }}>
        <Progress rows={m.rows} />
        {m.rows.map((r) => (
          <div key={r.id}>
            <RowLine row={r} />
          </div>
        ))}
        <Text size="small" tone="tertiary">{`Done when: ${m.doneWhen}`}</Text>
      </Stack>
    </CollapsibleSection>
  );
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
    <div style={{ display: "grid", gridTemplateColumns: "14px minmax(0, 1fr)", gap: 8, alignItems: "start", opacity: closed ? 0.6 : 1 }}>
      <div style={{ paddingTop: 4 }}>
        <Dot color={closed ? "green" : item.blocking ? "yellow" : "gray"} />
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

function NeedsYou({ marks, setMarks }: { marks: Marks; setMarks: SetMarks }) {
  const items = workstream.needsYou;
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
          {`${open.length} open, ${open.filter((item) => item.blocking).length || "none"} blocking`}
        </Text>
      </Row>
      {open.map((item) => (
        <div key={item.id}>
          <NeedsYouItem item={item} mark={marks[item.id]} onMark={markItem(item.id)} />
        </div>
      ))}
      {done.length > 0 && (
        <CollapsibleSection title="Done" count={done.length} defaultOpen={false}>
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

function Agents() {
  const dispatch = useCanvasAction();
  return (
    <Table
      headers={["Agent", "Rows", "How it ended", ""]}
      rows={AGENTS.map((a) => [
        a.title,
        a.row,
        a.ended,
        <Button key={a.id} variant="secondary" onClick={() => dispatch({ type: "openAgent", agentId: a.id })}>
          Open
        </Button>,
      ])}
      rowTone={AGENTS.map((a) => (a.ended === "Running" ? "info" : undefined))}
    />
  );
}

function Measurements() {
  return (
    <Stack gap={20}>
      <Grid columns={2} gap={24} align="start">
        {workstream.measurements.map((m) => (
          <div key={m.title}>
            <Stack gap={6}>
              <Text weight="semibold">{m.title}</Text>
              <BarChart
                categories={m.categories}
                series={m.series}
                valueSuffix={m.suffix}
                horizontal={m.horizontal}
                height={m.horizontal ? 320 : 220}
                referenceLines={m.budget ? [{ value: m.budget.value, label: m.budget.label, tone: "warning" }] : undefined}
              />
              <Text size="small" tone="tertiary">
                {m.caption}
              </Text>
            </Stack>
          </div>
        ))}
        {workstream.figures.map((f) => (
          <div key={f.title}>
            <Stack gap={6}>
              <Text weight="semibold">{f.title}</Text>
              <Table headers={["Measure", "Result", "Note"]} rows={f.rows} striped />
              <Text size="small" tone="tertiary">
                {f.caption}
              </Text>
            </Stack>
          </div>
        ))}
      </Grid>
    </Stack>
  );
}

function PlanSteps() {
  return (
    <Stack gap={8}>
      {workstream.plan.map((step) => (
        <div key={step.id} style={{ display: "grid", gridTemplateColumns: "14px minmax(0, 1fr) 200px", gap: 10, alignItems: "start" }}>
          <div style={{ paddingTop: 4 }}>
            <Dot color={STEP_COLOR[step.status]} />
          </div>
          <Stack gap={2}>
            <Text size="small" weight="semibold">
              {step.step}
            </Text>
            <Text size="small" tone="tertiary">
              {`Done when: ${step.doneWhen}`}
            </Text>
            {step.note ? <Text size="small">{step.note}</Text> : null}
          </Stack>
          <Text size="small" tone="secondary">
            {step.ref ?? ""}
          </Text>
        </div>
      ))}
    </Stack>
  );
}

function LogEntries({ now }: { now: number }) {
  return (
    <Stack gap={12}>
      {workstream.log.map((entry) => (
        <div key={entry.at} style={{ display: "grid", gridTemplateColumns: "112px minmax(0, 1fr)", gap: 10 }}>
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

// ---------------------------------------------------------------- the board

export default function WorkstreamBoard() {
  const now = useNow();
  const [marks, setMarks] = useCanvasState<Marks>("needsYou", {});
  const core = MILESTONES.flatMap((m) => m.rows);
  const active = MILESTONES.filter((m) => m.status === "active");
  const ahead = MILESTONES.filter((m) => m.status !== "active");
  return (
    <Stack gap={28} style={{ padding: 24, maxWidth: 1120 }}>
      <Stack gap={4}>
        <H1>{BOARD.title}</H1>
        <Text tone="secondary">
          {`${BOARD.lede} ${BOARD.scope} is ${percent(core)}% built: ${builtOrDone(core)} of ${core.length} rows built, ${count(core, "doing")} in progress. Working on ${active.map((m) => m.id).join(" and ")}. Updated ${ago(workstream.updated, now)} (${when(workstream.updated)}), up to ${workstream.lastCommit}.`}
        </Text>
      </Stack>

      <Roadmap />

      <Grid columns="minmax(0, 3fr) minmax(0, 2fr)" gap={24} align="start">
        <NowPanel />
        <NeedsYou marks={marks} setMarks={setMarks} />
      </Grid>

      <Stack gap={8}>
        <H2>In progress</H2>
        <Card>
          <CardBody>
            <Stack gap={4}>
              {active.map((m) => (
                <div key={m.id}>
                  <MilestoneDetail m={m} open />
                </div>
              ))}
            </Stack>
          </CardBody>
        </Card>
      </Stack>

      <Stack gap={8}>
        <H2>Ahead</H2>
        <Card>
          <CardBody>
            <Stack gap={4}>
              {[...ahead, LATER].map((m) => (
                <div key={m.id}>
                  <MilestoneDetail m={m} open={false} />
                </div>
              ))}
            </Stack>
          </CardBody>
        </Card>
      </Stack>

      <Stack gap={8}>
        <H2>Measured so far</H2>
        <Measurements />
      </Stack>

      <Stack gap={8}>
        <H2>Agents</H2>
        <Agents />
      </Stack>

      <Stack gap={4}>
        <H2>Record</H2>
        <CollapsibleSection title="The plan's steps" count={workstream.plan.length}>
          <PlanSteps />
        </CollapsibleSection>
        <CollapsibleSection title="Log" count={workstream.log.length}>
          <LogEntries now={now} />
        </CollapsibleSection>
        <CollapsibleSection title="Decisions" count={workstream.decisions.length}>
          <Table headers={["Date", "Decision", "Why", "By"]} rows={workstream.decisions.map((d) => [d.date, d.decision, d.why, d.by])} striped />
        </CollapsibleSection>
      </Stack>
      <Divider />
      <Text size="small" tone="tertiary">
        Row states come from the tracker and the commits; Built means merged and tested, with a check at scale or a small part still to do.
      </Text>
    </Stack>
  );
}
