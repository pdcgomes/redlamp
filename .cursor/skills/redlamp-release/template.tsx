import {
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
import type { SetCanvasState, StatTone } from "cursor/canvas";

// The release room (.cursor/skills/redlamp-release/SKILL.md): one canvas for every release, where
// the next one is prepared, checked, approved and shipped. Edit only `room` below; an empty list
// hides its section or tab.

type Stage = "preparing" | "awaiting approval" | "approved" | "releasing" | "released";
type CheckStatus = "not run" | "running" | "passed" | "failed" | "skipped" | "needs you";
type NewsStatus = "candidate" | "drafted" | "approved" | "published" | "dropped";
type Decision = "undecided" | "ship as is" | "fix first" | "leave out" | "later";
type StepStatus = "done" | "in progress" | "not started" | "blocked" | "dropped";

interface NeedsYouItem {
  id: string;
  title: string;
  /** Exactly what to do and where; once done, "Done: …" with what came of it. */
  detail: string;
  unblocks: string;
  blocking: boolean;
  done: boolean;
  command?: string;
}

interface Room {
  /** ISO with the time zone. */
  updated: string;
  latest: { version: string; date: string; url?: string };
  upcoming: {
    version: string;
    build: number;
    stage: Stage;
    /** Where it stands, in a sentence or two. */
    summary: string;
    /** What stands between here and releasing, in a sentence. */
    gate: string;
    /** The origin/main commit the room last read. */
    base: string;
  };
  stats: { value: string; label: string; tone?: StatTone }[];
  /** Approvals and choices only the owner makes; "Approve the release" is always last and blocking. */
  needsYou: NeedsYouItem[];
  /** What ships: tracker rows (or commits naming none) since the latest release. */
  scope: { ref: string; title: string; status: string; userFacing: boolean; commits: number; note?: string }[];
  /** What this release leaves out: unmerged branches, unpushed commits, work hidden for now. */
  heldBack: { title: string; detail: string }[];
  whatsNew: { id: string; title: string; status: NewsStatus; note: string }[];
  checks: { id: string; title: string; detail: string; command?: string; status: CheckStatus; result?: string; at?: string }[];
  problems: { id: string; title: string; kind: "bug" | "failing check" | "incomplete" | "limitation" | "risk"; source: string; decision: Decision; note: string }[];
  /** Run only once the release is approved. */
  steps: { id: string; step: string; detail: string; command?: string; status: StepStatus; ref?: string }[];
  history: { version: string; date: string; summary: string; url?: string }[];
  /** Newest first. */
  log: { at: string; text: string }[];
  decisions: { date: string; decision: string; why: string; by: "Owner" | "Measured" | "Default" }[];
  links: { label: string; target: string }[];
}

const room: Room = {
  updated: "2026-10-05T09:00:00+01:00",
  latest: { version: "0.2.3-prealpha", date: "2026-10-04", url: "https://github.com/pdcgomes/redlamp/releases/tag/v0.2.3-prealpha" },
  upcoming: {
    version: "0.2.4-prealpha",
    build: 567,
    stage: "preparing",
    summary: "Example: the camera bench and the filmstrip's context menu, with What's New for the first time.",
    gate: "Example: two checks to run and one problem to decide.",
    base: "e0ee6f9",
  },
  stats: [],
  needsYou: [
    {
      id: "approve-0.2.4",
      title: "Approve the release",
      detail: "Once every check has passed or been waived and every problem decided, approve it here or in the chat.",
      unblocks: "Running the release",
      blocking: true,
      done: false,
    },
  ],
  scope: [{ ref: "CAM-15", title: "The Camera Bench window", status: "Done", userFacing: true, commits: 8 }],
  heldBack: [],
  whatsNew: [{ id: "camera-bench", title: "Test your camera", status: "drafted", note: "Example." }],
  checks: [{ id: "suite", title: "The full test suite on this Mac", detail: "Example.", command: "xcodebuild test …", status: "not run" }],
  problems: [],
  steps: [{ id: "release", step: "mise run release", detail: "Example.", command: "mise run release", status: "not started" }],
  history: [{ version: "0.2.3-prealpha", date: "2026-10-04", summary: "Example." }],
  log: [{ at: "2026-10-05T09:00:00+01:00", text: "Example." }],
  decisions: [],
  links: [],
};

// ---------------------------------------------------------------- rendering (keys sit on wrapper divs)

const TABS = ["Overview", "Scope", "What's New", "Checks", "Problems", "Release plan", "History", "Log", "Decisions"] as const;
type Tab = (typeof TABS)[number];

type Mark = { state: "done" | "skipped" | "asked"; at: string };
type Marks = Record<string, Mark>;
type SetMarks = SetCanvasState<Marks>;
type Tone = "good" | "bad" | "waiting" | "active" | "quiet";

const CHECK_TONE: Record<CheckStatus, Tone> = {
  passed: "good",
  failed: "bad",
  "needs you": "waiting",
  running: "active",
  "not run": "quiet",
  skipped: "quiet",
};
const NEWS_TONE: Record<NewsStatus, Tone> = {
  approved: "good",
  published: "good",
  drafted: "active",
  candidate: "waiting",
  dropped: "quiet",
};
const DECISION_TONE: Record<Decision, Tone> = {
  undecided: "waiting",
  "fix first": "bad",
  "ship as is": "good",
  "leave out": "quiet",
  later: "quiet",
};
const STEP_TONE: Record<StepStatus, Tone> = {
  done: "good",
  "in progress": "active",
  "not started": "quiet",
  blocked: "waiting",
  dropped: "quiet",
};

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

function Dot({ tone }: { tone: Tone }) {
  const theme = useHostTheme();
  const color = {
    good: theme.category.green,
    bad: theme.category.red,
    waiting: theme.category.yellow,
    active: theme.accent.primary,
    quiet: theme.text.quaternary,
  }[tone];
  return <span style={{ display: "inline-block", width: 8, height: 8, borderRadius: 4, background: color, flexShrink: 0 }} />;
}

function Status({ tone, label }: { tone: Tone; label: string }) {
  return (
    <Row gap={6} align="center">
      <Dot tone={tone} />
      <Text size="small" tone="secondary">
        {label}
      </Text>
    </Row>
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

function settled(item: NeedsYouItem, marks: Marks): boolean {
  const state = marks[item.id]?.state;
  return item.done || state === "done" || state === "skipped";
}

function NeedsYouRow({ item, mark, onMark }: { item: NeedsYouItem; mark?: Mark; onMark: (state: Mark["state"] | null) => void }) {
  const dispatch = useCanvasAction();
  const closed = settled(item, mark ? { [item.id]: mark } : {});
  const ask = () => {
    onMark("asked");
    dispatch({
      type: "newComposerChat",
      userPrompt:
        `From the release room's Needs you list, please take on "${item.title}" (item ${item.id}) for ${room.upcoming.version}: ${item.detail}` +
        `${item.command ? ` The command: ${item.command}` : ""} ` +
        "Follow .cursor/skills/redlamp-release/SKILL.md, and update the release room with what came of it. Never run the release itself unless it has been approved.",
    });
  };
  return (
    <div style={{ display: "grid", gridTemplateColumns: "14px minmax(0, 1fr)", gap: 8, alignItems: "start", opacity: closed ? 0.6 : 1 }}>
      <div style={{ paddingTop: 6 }}>
        <Dot tone={closed ? "good" : item.blocking ? "waiting" : "quiet"} />
      </div>
      <Stack gap={3}>
        <Row gap={8} align="center">
          <Text size="small" weight="semibold">
            {item.title}
          </Text>
          {item.blocking && !closed ? <Pill size="sm">Blocks the release</Pill> : null}
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
              {item.id.startsWith("approve") ? "Approve" : "Done"}
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
  const markItem = (id: string) => (state: Mark["state"] | null) =>
    setMarks((previous) => {
      const next = { ...previous };
      if (state) next[id] = { state, at: new Date().toISOString() };
      else delete next[id];
      return next;
    });
  const open = room.needsYou.filter((item) => !settled(item, marks));
  const done = room.needsYou.filter((item) => settled(item, marks));
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
          <NeedsYouRow item={item} mark={marks[item.id]} onMark={markItem(item.id)} />
        </div>
      ))}
      {done.length > 0 && (
        <CollapsibleSection title="Done" count={done.length} defaultOpen={open.length === 0}>
          <Stack gap={10}>
            {done.map((item) => (
              <div key={item.id}>
                <NeedsYouRow item={item} mark={marks[item.id]} onMark={markItem(item.id)} />
              </div>
            ))}
          </Stack>
        </CollapsibleSection>
      )}
    </Stack>
  );
}

function LogEntries({ entries, now }: { entries: Room["log"]; now: number }) {
  return (
    <Stack gap={12}>
      {entries.map((entry) => (
        <div key={`${entry.at}-${entry.text.slice(0, 32)}`} style={{ display: "grid", gridTemplateColumns: "112px minmax(0, 1fr)", gap: 10 }}>
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

/** One line per area: how far it has got, at a glance. */
function Readiness() {
  const checks = room.checks.filter((check) => check.status !== "skipped");
  const passed = checks.filter((check) => check.status === "passed").length;
  const failed = checks.filter((check) => check.status === "failed").length;
  const news = room.whatsNew.filter((item) => item.status !== "dropped");
  const newsReady = news.filter((item) => item.status === "approved" || item.status === "published").length;
  const undecided = room.problems.filter((problem) => problem.decision === "undecided").length;
  const fixFirst = room.problems.filter((problem) => problem.decision === "fix first").length;
  const stepsDone = room.steps.filter((step) => step.status === "done").length;
  const lines: { area: string; tone: Tone; text: string }[] = [
    {
      area: "Scope",
      tone: room.heldBack.length ? "waiting" : "good",
      text: `${room.scope.length} changes since ${room.latest.version}${room.heldBack.length ? `; ${room.heldBack.length} held back` : ""}`,
    },
    {
      area: "What's New",
      tone: news.length === 0 ? "waiting" : newsReady === news.length ? "good" : "active",
      text: news.length ? `${newsReady} of ${news.length} highlights approved` : "No highlights chosen",
    },
    {
      area: "Checks",
      tone: failed ? "bad" : checks.length && passed === checks.length ? "good" : passed ? "active" : "quiet",
      text: `${passed} of ${checks.length} passed${failed ? `, ${failed} failed` : ""}`,
    },
    {
      area: "Problems",
      tone: fixFirst ? "bad" : undecided ? "waiting" : "good",
      text: room.problems.length ? `${undecided} undecided${fixFirst ? `, ${fixFirst} to fix first` : ""} of ${room.problems.length}` : "None known",
    },
    {
      area: "Release plan",
      tone: stepsDone === room.steps.length && room.steps.length ? "good" : stepsDone ? "active" : "quiet",
      text: room.upcoming.stage === "approved" || stepsDone ? `${stepsDone} of ${room.steps.length} steps done` : "Waits on approval",
    },
  ];
  return (
    <Stack gap={8}>
      {lines.map((line) => (
        <div key={line.area} style={{ display: "grid", gridTemplateColumns: "14px 110px minmax(0, 1fr)", gap: 8, alignItems: "center" }}>
          <Dot tone={line.tone} />
          <Text size="small" weight="semibold">
            {line.area}
          </Text>
          <Text size="small" tone="secondary">
            {line.text}
          </Text>
        </div>
      ))}
    </Stack>
  );
}

function OverviewTab({ now, marks, setMarks }: { now: number; marks: Marks; setMarks: SetMarks }) {
  return (
    <Grid columns="minmax(0, 1.4fr) minmax(0, 1fr)" gap={28} align="start">
      <Stack gap={22}>
        <Stack gap={10}>
          <H2>Readiness</H2>
          <Readiness />
        </Stack>
        {room.heldBack.length > 0 && (
          <Stack gap={8}>
            <H3>Held back</H3>
            {room.heldBack.map((item) => (
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
        )}
        {room.log.length > 0 && (
          <Stack gap={10}>
            <H3>Latest</H3>
            <LogEntries entries={room.log.slice(0, 3)} now={now} />
          </Stack>
        )}
      </Stack>
      {room.needsYou.length > 0 && <NeedsYou marks={marks} setMarks={setMarks} />}
    </Grid>
  );
}

function ListRows<T>({ items, render }: { items: T[]; render: (item: T) => { key: string; title: string; detail?: string; status: { tone: Tone; label: string }; aside?: string; command?: string } }) {
  const theme = useHostTheme();
  return (
    <Stack gap={0}>
      {items.map((item, index) => {
        const row = render(item);
        return (
          <div
            key={row.key}
            style={{
              display: "grid",
              gridTemplateColumns: "minmax(0, 1fr) 140px 130px",
              gap: 12,
              alignItems: "start",
              padding: "10px 0",
              borderTop: index === 0 ? `1px solid ${theme.stroke.tertiary}` : undefined,
              borderBottom: `1px solid ${theme.stroke.tertiary}`,
            }}
          >
            <Stack gap={3}>
              <Text weight="semibold">{row.title}</Text>
              {row.detail ? (
                <Text size="small" tone="secondary">
                  {row.detail}
                </Text>
              ) : null}
              {row.command ? <CommandBlock command={row.command} /> : null}
            </Stack>
            <Text size="small" tone="tertiary">
              {row.aside ?? ""}
            </Text>
            <Status tone={row.status.tone} label={row.status.label} />
          </div>
        );
      })}
    </Stack>
  );
}

export default function ReleaseRoom() {
  const now = useNow();
  const [marks, setMarks] = useCanvasState<Marks>("needsYou", {});
  const shown: Record<Tab, boolean> = {
    Overview: true,
    Scope: room.scope.length > 0,
    "What's New": room.whatsNew.length > 0,
    Checks: room.checks.length > 0,
    Problems: room.problems.length > 0,
    "Release plan": room.steps.length > 0,
    History: room.history.length > 0,
    Log: room.log.length > 0,
    Decisions: room.decisions.length > 0,
  };
  const tabs = TABS.filter((tab) => shown[tab]);
  const [selected, setSelected] = useCanvasState<Tab>("tab", "Overview");
  const tab: Tab = shown[selected] ? selected : "Overview";
  const open = room.needsYou.filter((item) => !settled(item, marks));
  const blocking = open.filter((item) => item.blocking).length;
  const checks = room.checks.filter((check) => check.status !== "skipped");
  const passed = checks.filter((check) => check.status === "passed").length;
  return (
    <Stack gap={18} style={{ padding: 4 }}>
      <Stack gap={6}>
        <Row gap={10} align="center">
          <H1>{`Release room: ${room.upcoming.version}`}</H1>
          <Pill>{room.upcoming.stage}</Pill>
        </Row>
        <Text tone="secondary">
          {`Latest release ${room.latest.version} (${room.latest.date}). Upcoming ${room.upcoming.version}, build ${room.upcoming.build}, from origin/main at ${room.upcoming.base}.`}
        </Text>
        <Text>{room.upcoming.summary}</Text>
        <Text size="small" weight="medium">{`Before it ships: ${room.upcoming.gate}`}</Text>
        <Text size="small" tone="tertiary">
          {`Updated ${ago(room.updated, now)} (${when(room.updated)})`}
        </Text>
      </Stack>

      <Row gap={32} wrap>
        {checks.length > 0 && <Stat value={`${passed} of ${checks.length}`} label="Checks passed" tone={passed === checks.length ? "success" : undefined} />}
        <Stat value={`${open.length}`} label={blocking ? `Waiting on you, ${blocking} blocking` : "Waiting on you"} tone={blocking ? "warning" : undefined} />
        {room.stats.map((stat) => (
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
                {name}
              </Pill>
            </span>
          ))}
        </Row>
      )}
      <Divider />

      {tab === "Overview" && <OverviewTab now={now} marks={marks} setMarks={setMarks} />}
      {tab === "Scope" && (
        <ListRows
          items={room.scope}
          render={(item) => ({
            key: item.ref,
            title: `${item.ref}: ${item.title}`,
            detail: item.note,
            aside: `${item.commits} commit${item.commits === 1 ? "" : "s"}${item.userFacing ? "" : ", internal"}`,
            status: { tone: item.status === "Done" ? "good" : "waiting", label: item.status },
          })}
        />
      )}
      {tab === "What's New" && (
        <ListRows
          items={room.whatsNew}
          render={(item) => ({ key: item.id, title: item.title, detail: item.note, aside: item.id, status: { tone: NEWS_TONE[item.status], label: item.status } })}
        />
      )}
      {tab === "Checks" && (
        <ListRows
          items={room.checks}
          render={(check) => ({
            key: check.id,
            title: check.title,
            detail: [check.detail, check.result].filter(Boolean).join(" "),
            command: check.status === "passed" ? undefined : check.command,
            aside: check.at ? when(check.at) : "",
            status: { tone: CHECK_TONE[check.status], label: check.status },
          })}
        />
      )}
      {tab === "Problems" && (
        <ListRows
          items={room.problems}
          render={(problem) => ({
            key: problem.id,
            title: problem.title,
            detail: problem.note,
            aside: `${problem.kind} · ${problem.source}`,
            status: { tone: DECISION_TONE[problem.decision], label: problem.decision },
          })}
        />
      )}
      {tab === "Release plan" && (
        <ListRows
          items={room.steps}
          render={(step) => ({
            key: step.id,
            title: step.step,
            detail: step.detail,
            command: step.status === "done" ? undefined : step.command,
            aside: step.ref ?? "",
            status: { tone: STEP_TONE[step.status], label: step.status },
          })}
        />
      )}
      {tab === "History" && (
        <Table headers={["Version", "Date", "What it brought"]} rows={room.history.map((release) => [release.version, release.date, release.summary])} striped />
      )}
      {tab === "Log" && <LogEntries entries={room.log} now={now} />}
      {tab === "Decisions" && (
        <Table headers={["Date", "Decision", "Why", "By"]} rows={room.decisions.map((d) => [d.date, d.decision, d.why, d.by])} striped />
      )}
      {room.links.length > 0 && (
        <Text size="small" tone="tertiary">
          {room.links.map((link) => `${link.label}: ${link.target}`).join(" · ")}
        </Text>
      )}
    </Stack>
  );
}
