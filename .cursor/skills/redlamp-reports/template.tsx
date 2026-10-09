import {
  Button,
  CollapsibleSection,
  Divider,
  H1,
  H2,
  H3,
  Link,
  Pill,
  Row,
  Spacer,
  Stack,
  Stat,
  Table,
  Text,
  TextInput,
  useCanvasAction,
  useCanvasState,
  useEffect,
  useHostTheme,
  useState,
} from "cursor/canvas";
import type { SetCanvasState } from "cursor/canvas";

// The reports room (.cursor/skills/redlamp-reports/SKILL.md): every report filed on GitHub, from
// triage to the release that ships its fix. room.py sync writes DATA, in the block marked below;
// edit only `room`. The owner's clicks are kept under `triage` in the canvas's data file, which
// room.py reads and never writes.

type Kind = "bug" | "idea" | "question" | "unsorted";
type Decision = "fix" | "close" | "accept" | "reject" | "answer";

interface Triage {
  decision: Decision;
  at: string;
  reason?: string | null;
  /** What applying it did; empty while it waits to be applied. */
  applied?: string | null;
  token?: string | null;
}

interface Commit {
  short: string;
  at: string;
  subject: string;
}

/** An earlier try at a report that was reopened: its triage, its agent and what came of it. */
interface Round {
  triage: Triage | null;
  agent: { chat: string | null; title?: string | null; started: string; token?: string | null } | null;
  stage: string | null;
  reproduced: "yes" | "not needed" | "couldn't" | null;
  reply: { url: string | null; at: string | null; release: string | null; fromComments?: boolean } | null;
  out: { url: string; at: string } | null;
  commits: string[];
  release: string | null;
}

interface Report {
  number: number;
  title: string;
  url: string;
  kind: Kind;
  area: string | null;
  often: string | null;
  from: string | null;
  version: string | null;
  reporter: { inApp: boolean; login: string | null };
  labels: string[];
  opened: string;
  state: "open" | "closed";
  stateReason: string | null;
  closed: string | null;
  /** The report's own sections: What happened, What I expected, Steps to reproduce, What I'd like to do… */
  words: Record<string, string>;
  screenshots: number;
  diagnostics: string | null;
  comments: { by: string; you: boolean; at: string; text: string; url?: string | null }[];
  triage: Triage | null;
  read: { at: string; text: string } | null;
  /** For a suggestion: what Accept does. */
  proposal: { kind: "new row" | "follows" | "duplicate"; id?: string; text?: string; phase?: string; reply?: string } | null;
  agent: { chat: string | null; title?: string | null; started: string; token?: string | null } | null;
  stage: string | null;
  waiting: "you" | "reporter" | null;
  why: string | null;
  reproduced: "yes" | "not needed" | "couldn't" | null;
  /** Commits naming the issue that aren't on origin/main. */
  branches: { branch: string; worktree: string | null; commits: Commit[] }[];
  fix: { commits: Commit[]; insideApp: boolean; state: "expected" | "released" | "live" | "missed"; version: string | null; promised: string | null } | null;
  reply: { url: string | null; at: string | null; release: string | null; fromComments?: boolean } | null;
  out: { url: string; at: string } | null;
  /** The last time the issue was reopened after a fix; the work before it is in `rounds`. */
  reopened: { at: string; by: string | null } | null;
  rounds: Round[];
  tracked: string | null;
  notes: { at: string; text: string }[];
  thumb: string | null;
}

interface Data {
  checked: string;
  changed: string;
  release: {
    latest: { version: string; date: string } | null;
    upcoming: string | null;
    stage: string | null;
    candidate: string | null;
    roomVersion: string | null;
    error?: string;
  };
  reports: Report[];
  log: { at: string; text: string }[];
  owner: string;
  repo: string;
  notesDir: string;
  script: string;
}

interface Room {
  /** Appended as they happen; a reversed decision is a new row. */
  decisions: { date: string; decision: string; why: string; by: "Owner" | "Measured" | "Default" }[];
  links: { label: string; target: string }[];
}

const room: Room = {
  decisions: [],
  links: [],
};

// REPORTS:BEGIN (room.py sync writes this block; never edit it by hand)
const DATA: Data = {
  "checked": "2026-10-07T14:00:00+01:00",
  "changed": "2026-10-07T14:00:00+01:00",
  "release": { "latest": null, "upcoming": null, "stage": null, "candidate": null, "roomVersion": null },
  "reports": [],
  "log": [],
  "owner": "pdcgomes",
  "repo": "pdcgomes/redlamp",
  "notesDir": "",
  "script": ""
};
// REPORTS:END

// ---------------------------------------------------------------- rendering (keys sit on wrapper divs)

const SKILL = ".cursor/skills/redlamp-reports/SKILL.md";
const BRIEF = ".cursor/skills/redlamp-reports/bug-agent.md";
const TABS = ["Triage", "Bugs", "Suggestions", "Released", "Log", "Decisions"] as const;
type Tab = (typeof TABS)[number];
type Tone = "good" | "bad" | "waiting" | "active" | "quiet";
type Marks = Record<string, Triage>;
type SetMarks = SetCanvasState<Marks>;

const KIND_LABEL: Record<Kind, string> = { bug: "Bug", idea: "Suggestion", question: "Question", unsorted: "Not sorted" };

function useNow(intervalMs = 30000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(timer);
  }, [intervalMs]);
  return now;
}

function ago(iso: string | null | undefined, now: number): string {
  if (!iso) return "";
  const ms = now - Date.parse(iso);
  if (Number.isNaN(ms)) return iso;
  const minutes = Math.max(0, Math.round(ms / 60000));
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} h ${minutes % 60} min ago`;
  return `${Math.floor(hours / 24)} d ago`;
}

function when(iso: string | null | undefined): string {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return date.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

function Dot({ tone, size = 8 }: { tone: Tone; size?: number }) {
  const theme = useHostTheme();
  const color = {
    good: theme.category.green,
    bad: theme.category.red,
    waiting: theme.category.yellow,
    active: theme.accent.primary,
    quiet: theme.text.quaternary,
  }[tone];
  return <span style={{ display: "inline-block", width: size, height: size, borderRadius: size / 2, background: color, flexShrink: 0 }} />;
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

// ---------------------------------------------------------------- what each report's state is

function time(iso: string | null | undefined): number {
  const value = Date.parse(iso ?? "");
  return Number.isNaN(value) ? 0 : value;
}

function decisionOf(report: Report, marks: Marks): Triage | null {
  const mark = marks[String(report.number)];
  const current = mark && (!report.reopened || time(mark.at) > time(report.reopened.at));
  if (mark && current && (!report.triage || time(mark.at) > time(report.triage.at))) return { ...mark, applied: null };
  return report.triage;
}

function waitsForTriage(report: Report, marks: Marks): boolean {
  return report.state === "open" && !decisionOf(report, marks) && !report.agent;
}

function waitsToBeApplied(report: Report, marks: Marks): boolean {
  const decision = decisionOf(report, marks);
  return !!decision && decision.decision !== "fix" && decision.decision !== "answer" && !decision.applied && report.state === "open";
}

function isBug(report: Report, marks: Marks): boolean {
  const decision = decisionOf(report, marks)?.decision;
  return report.kind === "bug" || decision === "fix" || !!report.agent || !!report.fix;
}

function atWork(report: Report): boolean {
  return !!report.agent && report.state === "open";
}

function upcoming(): string {
  return DATA.release.upcoming ?? "the upcoming release";
}

function landedForUpcoming(report: Report): boolean {
  return !!report.fix && (report.fix.state === "expected" || report.fix.state === "missed");
}

function reporterText(report: Report): string {
  if (report.reporter.inApp) return report.reporter.login ? `${report.reporter.login}, from the app` : "Someone using the app";
  return report.reporter.login ? `${report.reporter.login} on GitHub` : "On GitHub";
}

function releaseText(fix: NonNullable<Report["fix"]>): string {
  if (fix.state === "live") return "Out: the fix is outside the app";
  if (fix.state === "released") return `Released in ${fix.version}`;
  if (fix.state === "missed") return `Missed ${fix.promised}; expected in ${fix.version}`;
  return `Expected in ${fix.version}`;
}

// ---------------------------------------------------------------- prompts for the chats the buttons open

function reopenedText(report: Report): string {
  const earlier = report.rounds[report.rounds.length - 1];
  if (!report.reopened || !earlier) return "";
  return (
    `It was reopened on ${when(report.reopened.at)} after the earlier fix (${earlier.commits.join(", ") || "no commits recorded"}` +
    `${earlier.release ? `, released in ${earlier.release.replace(/^v/, "")}` : ""}) didn't fix it for the reporter; read their latest comment and the earlier round ` +
    `(room.py status, and the first agent's chat ${earlier.agent?.chat ?? "(not recorded)"} in the agent transcripts), and find out why that fix wasn't enough before changing anything. `
  );
}

function fixPrompt(report: Report, token: string): string {
  const short = report.title.replace(/^\[[^\]]*\]\s*/, "").slice(0, 60);
  return (
    `Fix bug #${report.number} from the reports room: "${report.title}" (${report.url}). ` +
    reopenedText(report) +
    `Follow ${BRIEF} from start to finish: claim it with room.py using the token ${token}, read the report and its diagnostics, ` +
    `reproduce it if it isn't obvious, fix it in a worktree of your own, push the fix to main through the push gate, ` +
    `then comment on #${report.number} with the cause, the fix and the release it's expected in, and close it. ` +
    `Please rename this chat "Bug #${report.number}: ${short}". Record each step with room.py and sync the room.`
  );
}

function askPrompt(report: Report): string {
  return (
    `Look into #${report.number} in the reports room for me ("${report.title}", ${report.url}) and tell me what you find: what it is, ` +
    `whether something already tracks it, whether main has fixed it since ${report.version ?? "the reporter's version"}, and what you'd do. ` +
    `Don't change anything on GitHub or in the code. Follow ${SKILL}, write your read into the room with room.py note --read, and sync it.`
  );
}

function answerPrompt(report: Report, token: string): string {
  return (
    `Answer question #${report.number} from the reports room ("${report.title}", ${report.url}), as ${SKILL} says under Questions: ` +
    `from the README, the docs and the manual, in my voice. Record it with room.py (token ${token}) and sync the room.`
  );
}

// ---------------------------------------------------------------- pieces

function Words({ report }: { report: Report }) {
  const entries = Object.entries(report.words);
  if (entries.length === 0) return null;
  return (
    <Stack gap={8}>
      {entries.map(([title, text]) => (
        <div key={title}>
          <Stack gap={2}>
            <Text size="small" tone="tertiary">
              {title}
            </Text>
            <Text size="small" style={{ whiteSpace: "pre-wrap" }}>
              {text}
            </Text>
          </Stack>
        </div>
      ))}
    </Stack>
  );
}

function Comments({ report, now, limit = 3 }: { report: Report; now: number; limit?: number }) {
  const shown = report.comments.slice(-limit);
  if (shown.length === 0) return null;
  return (
    <Stack gap={6}>
      {shown.map((comment) => (
        <div key={`${comment.at}-${comment.by}`} style={{ display: "grid", gridTemplateColumns: "120px minmax(0, 1fr)", gap: 10 }}>
          <Text size="small" tone="tertiary">
            {`${comment.you ? "You" : comment.by}, ${ago(comment.at, now)}`}
          </Text>
          <Text size="small" tone="secondary">
            {comment.text}
          </Text>
        </div>
      ))}
    </Stack>
  );
}

function Facts({ report, now }: { report: Report; now: number }) {
  const facts = [
    KIND_LABEL[report.kind],
    report.area,
    report.often,
    reporterText(report),
    `filed ${ago(report.opened, now)}`,
    report.screenshots ? `${report.screenshots} screenshot${report.screenshots === 1 ? "" : "s"}` : null,
  ].filter(Boolean);
  return (
    <Text size="small" tone="tertiary">
      {facts.join(" · ")}
    </Text>
  );
}

/** For a reopened report: when, and what the earlier round did, with its agent's chat. */
function EarlierRound({ report, now }: { report: Report; now: number }) {
  const theme = useHostTheme();
  const dispatch = useCanvasAction();
  const earlier = report.rounds[report.rounds.length - 1];
  if (!report.reopened) return null;
  const by = report.reopened.by === DATA.owner ? "you" : report.reopened.by;
  return (
    <div style={{ borderLeft: `2px solid ${theme.category.yellow}`, paddingLeft: 10 }}>
      <Stack gap={4}>
        <Text size="small" weight="semibold">{`Reopened${by ? ` by ${by}` : ""}, ${ago(report.reopened.at, now)}`}</Text>
        {earlier ? (
          <Text size="small" tone="secondary">
            {`The earlier round: fixed in ${earlier.commits.join(", ") || "commits not recorded"}${earlier.release ? `, released in ${earlier.release.replace(/^v/, "")}` : ""}. `}
            {earlier.reply?.url ? <Link href={earlier.reply.url}>Its reply</Link> : null}
            {earlier.out?.url ? (
              <>
                {", "}
                <Link href={earlier.out.url}>told it's out</Link>
              </>
            ) : null}
          </Text>
        ) : null}
        {earlier?.agent?.chat ? (
          <div>
            <Button variant="ghost" onClick={() => dispatch({ type: "openAgent", agentId: earlier.agent?.chat ?? "" })}>
              Open the first agent's chat
            </Button>
          </div>
        ) : null}
      </Stack>
    </div>
  );
}

function Title({ report }: { report: Report }) {
  return (
    <Text weight="semibold">
      <Link href={report.url}>{`#${report.number}`}</Link> {report.title}
    </Text>
  );
}

function ReasonInput({ id, reasons, setReasons, placeholder }: { id: string; reasons: Record<string, string>; setReasons: SetCanvasState<Record<string, string>>; placeholder: string }) {
  return (
    <TextInput
      value={reasons[id] ?? ""}
      onChange={(value) => setReasons((previous) => ({ ...previous, [id]: value }))}
      placeholder={placeholder}
      style={{ maxWidth: 420 }}
    />
  );
}

// ---------------------------------------------------------------- triage

function TriageCard(props: {
  report: Report;
  now: number;
  marks: Marks;
  setMarks: SetMarks;
  reasons: Record<string, string>;
  setReasons: SetCanvasState<Record<string, string>>;
}) {
  const { report, now, marks, setMarks, reasons, setReasons } = props;
  const theme = useHostTheme();
  const dispatch = useCanvasAction();
  const [closing, setClosing] = useState(false);
  const id = String(report.number);
  const mark = (decision: Decision, extra: Partial<Triage> = {}) =>
    setMarks((previous) => ({ ...previous, [id]: { decision, at: new Date().toISOString(), ...extra } }));
  const fix = () => {
    const token = `reports-room-fix-${report.number}-${Date.now()}`;
    mark("fix", { token });
    dispatch({ type: "newComposerChat", userPrompt: fixPrompt(report, token) });
  };
  const answer = () => {
    const token = `reports-room-answer-${report.number}-${Date.now()}`;
    mark("answer", { token });
    dispatch({ type: "newComposerChat", userPrompt: answerPrompt(report, token) });
  };
  const reason = (reasons[id] ?? "").trim();
  const kind = report.kind;
  const accept =
    report.proposal?.kind === "new row"
      ? `Accept as ${report.proposal.id ?? "a new row"}`
      : report.proposal?.kind === "follows"
        ? `Accept: follows ${report.proposal.id}`
        : report.proposal?.kind === "duplicate"
          ? `Accept: a duplicate of ${report.proposal.id}`
          : "Accept";
  return (
    <div style={{ display: "grid", gridTemplateColumns: report.thumb ? "minmax(0, 1fr) 200px" : "minmax(0, 1fr)", gap: 18, padding: "14px 0", borderBottom: `1px solid ${theme.stroke.tertiary}` }}>
      <Stack gap={10}>
        <Stack gap={3}>
          <Title report={report} />
          <Facts report={report} now={now} />
          {report.from ? (
            <Text size="small" tone="tertiary">
              {report.from}
            </Text>
          ) : null}
        </Stack>
        <Words report={report} />
        <EarlierRound report={report} now={now} />
        {report.read ? (
          <div style={{ background: theme.fill.tertiary, borderRadius: 6, padding: "8px 10px" }}>
            <Stack gap={2}>
              <Text size="small" tone="tertiary">{`An agent's read, ${ago(report.read.at, now)}`}</Text>
              <Text size="small">{report.read.text}</Text>
            </Stack>
          </div>
        ) : null}
        {report.proposal && kind !== "bug" ? (
          <Text size="small">
            <Text size="small" weight="semibold">{`Proposal: `}</Text>
            {[report.proposal.kind === "new row" ? `a new tracker row ${report.proposal.id ?? ""}` : `${report.proposal.kind} ${report.proposal.id ?? ""}`, report.proposal.phase, report.proposal.text]
              .filter(Boolean)
              .join(" · ")}
          </Text>
        ) : null}
        <Comments report={report} now={now} />
        {report.diagnostics ? (
          <Text size="small" tone="tertiary">
            <Link href={report.diagnostics}>diagnostics.json</Link> has the photo's edit in the sidecar format, its activity and the Mac's details.
          </Text>
        ) : null}
        <Row gap={6} wrap>
          {kind === "bug" || kind === "unsorted" ? (
            <Button variant="primary" onClick={fix}>
              {report.reopened ? "Fix it again" : "Fix it"}
            </Button>
          ) : null}
          {kind === "idea" || kind === "unsorted" ? (
            <Button variant={kind === "idea" ? "primary" : "secondary"} onClick={() => mark("accept")}>
              {accept}
            </Button>
          ) : null}
          {kind === "question" ? (
            <Button variant="primary" onClick={answer}>
              Answer it
            </Button>
          ) : null}
          <Button variant="secondary" onClick={() => setClosing(!closing)}>
            {kind === "idea" ? "Reject…" : "Close…"}
          </Button>
          <Button variant="ghost" onClick={() => dispatch({ type: "newComposerChat", userPrompt: askPrompt(report) })}>
            Ask the agent
          </Button>
        </Row>
        {closing ? (
          <Row gap={6} align="center" wrap>
            <ReasonInput id={id} reasons={reasons} setReasons={setReasons} placeholder={kind === "idea" ? "Why not, in a sentence for the reporter" : "Why it's closed, in a sentence for the reporter"} />
            <Button variant="secondary" disabled={!reason} onClick={() => mark(kind === "idea" ? "reject" : "close", { reason })}>
              {kind === "idea" ? "Reject it" : "Close it"}
            </Button>
          </Row>
        ) : null}
      </Stack>
      {report.thumb ? (
        <div>
          <img src={report.thumb} alt={`The first screenshot of #${report.number}`} style={{ width: 200, borderRadius: 6, display: "block" }} />
        </div>
      ) : null}
    </div>
  );
}

function DecidedRow({ report, marks, setMarks }: { report: Report; marks: Marks; setMarks: SetMarks }) {
  const decision = decisionOf(report, marks);
  if (!decision) return null;
  const label = {
    fix: "Fix it",
    close: "Close",
    accept: report.proposal?.id ? `Accept (${report.proposal.kind} ${report.proposal.id})` : "Accept",
    reject: "Reject",
    answer: "Answer it",
  }[decision.decision];
  const undo = () =>
    setMarks((previous) => {
      const next = { ...previous };
      delete next[String(report.number)];
      return next;
    });
  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) auto", gap: 10, alignItems: "center" }}>
      <Stack gap={2}>
        <Title report={report} />
        <Text size="small" tone="secondary">
          {`${label}${decision.reason ? `: ${decision.reason}` : ""}, ${when(decision.at)}. Waits to be applied.`}
        </Text>
      </Stack>
      {marks[String(report.number)] ? (
        <Button variant="ghost" onClick={undo}>
          Undo
        </Button>
      ) : null}
    </div>
  );
}

function applyPrompt(reports: Report[], marks: Marks): string {
  const items = reports
    .map((report) => {
      const decision = decisionOf(report, marks);
      return decision ? `#${report.number} ${decision.decision}${decision.reason ? ` (${decision.reason})` : ""}` : null;
    })
    .filter(Boolean)
    .join("; ");
  return `Apply my triage decisions in the reports room: ${items}. Follow ${SKILL} (Applying decisions), record each with room.py and sync the room.`;
}

function TriageTab(props: { now: number; marks: Marks; setMarks: SetMarks; reasons: Record<string, string>; setReasons: SetCanvasState<Record<string, string>> }) {
  const { marks } = props;
  const dispatch = useCanvasAction();
  const waiting = DATA.reports.filter((report) => waitsForTriage(report, marks));
  const decided = DATA.reports.filter((report) => waitsToBeApplied(report, marks));
  const unpicked = DATA.reports.filter((report) => decisionOf(report, marks)?.decision === "fix" && !report.agent && report.state === "open");
  return (
    <Stack gap={22}>
      {decided.length > 0 && (
        <Stack gap={10}>
          <Row gap={8} align="center">
            <H3>Decided, waiting to be applied</H3>
            <Spacer />
            <Button variant="primary" onClick={() => dispatch({ type: "newComposerChat", userPrompt: applyPrompt(decided, marks) })}>
              {`Apply decisions (${decided.length})`}
            </Button>
          </Row>
          {decided.map((report) => (
            <div key={report.number}>
              <DecidedRow report={report} marks={marks} setMarks={props.setMarks} />
            </div>
          ))}
        </Stack>
      )}
      {unpicked.length > 0 && (
        <Stack gap={10}>
          <H3>Fix it, no agent has picked it up yet</H3>
          {unpicked.map((report) => (
            <div key={report.number}>
              <Unpicked report={report} marks={marks} setMarks={props.setMarks} now={props.now} />
            </div>
          ))}
        </Stack>
      )}
      {waiting.length > 0 ? (
        <Stack gap={0}>
          <H3>{`Waiting for your triage (${waiting.length})`}</H3>
          {waiting.map((report) => (
            <div key={report.number}>
              <TriageCard report={report} {...props} />
            </div>
          ))}
        </Stack>
      ) : (
        <Text tone="secondary">Every report has been triaged.</Text>
      )}
    </Stack>
  );
}

function Unpicked({ report, marks, setMarks, now }: { report: Report; marks: Marks; setMarks: SetMarks; now: number }) {
  const dispatch = useCanvasAction();
  const decision = decisionOf(report, marks);
  const again = () => {
    const token = `reports-room-fix-${report.number}-${Date.now()}`;
    setMarks((previous) => ({ ...previous, [String(report.number)]: { decision: "fix", at: new Date().toISOString(), token } }));
    dispatch({ type: "newComposerChat", userPrompt: fixPrompt(report, token) });
  };
  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) auto", gap: 10, alignItems: "center" }}>
      <Stack gap={2}>
        <Title report={report} />
        <Text size="small" tone="secondary">
          {`You chose Fix it ${ago(decision?.at, now)}; the room hasn't heard from its agent since. Its chat claims it when it starts.`}
        </Text>
      </Stack>
      <Button variant="secondary" onClick={again}>
        Start its agent again
      </Button>
    </div>
  );
}

// ---------------------------------------------------------------- bugs

const TRACK = ["Reported", "Triaged", "Reproduced", "Fixed", "On main", "Replied", "Released"] as const;
type StepState = "done" | "current" | "waiting" | "todo";

function track(report: Report, marks: Marks): { label: string; state: StepState }[] {
  const decision = decisionOf(report, marks);
  const stage = report.stage ?? "";
  const pastReproducing = ["fixing", "testing", "pushing", "landed", "replied"].includes(stage);
  const done = [
    true,
    !!decision || !!report.agent || !!report.fix,
    report.reproduced === "yes" || report.reproduced === "not needed" || pastReproducing || !!report.fix,
    ["testing", "pushing", "landed", "replied"].includes(stage) || !!report.fix,
    !!report.fix,
    !!report.reply || (!!report.fix && report.state === "closed"),
    !!report.fix && (report.fix.state === "released" || report.fix.state === "live"),
  ];
  const labels: string[] = [...TRACK];
  if (report.reproduced === "not needed") labels[2] = "Not needed";
  if (report.reproduced === "couldn't") labels[2] = "Couldn't";
  if (report.fix) labels[6] = report.fix.state === "live" ? "Out" : report.fix.state === "released" ? `In ${report.fix.version}` : `Due ${report.fix.version}`;
  const first = done.findIndex((d) => !d);
  return labels.map((label, index) => ({
    label,
    state: done[index] ? "done" : index === first ? (report.waiting ? "waiting" : atWork(report) || report.fix ? "current" : "todo") : "todo",
  }));
}

function Track({ steps }: { steps: { label: string; state: StepState }[] }) {
  const theme = useHostTheme();
  return (
    <div style={{ display: "grid", gridTemplateColumns: `repeat(${steps.length}, minmax(0, 1fr))`, gap: 0 }}>
      {steps.map((step, index) => (
        <div key={step.label + index} style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <div style={{ display: "flex", alignItems: "center" }}>
            <span
              style={{
                width: 10,
                height: 10,
                borderRadius: 5,
                flexShrink: 0,
                boxSizing: "border-box",
                background: step.state === "done" ? theme.accent.primary : "transparent",
                border: `2px solid ${step.state === "todo" ? theme.text.quaternary : step.state === "waiting" ? theme.category.yellow : theme.accent.primary}`,
              }}
            />
            {index < steps.length - 1 ? <span style={{ flex: 1, height: 1, background: step.state === "done" ? theme.accent.primary : theme.stroke.tertiary }} /> : null}
          </div>
          <Text size="small" tone={step.state === "todo" ? "tertiary" : "secondary"} style={{ paddingRight: 4 }}>
            {step.label}
          </Text>
        </div>
      ))}
    </div>
  );
}

function bugStatus(report: Report, marks: Marks): { tone: Tone; label: string } {
  if (report.waiting === "you") return { tone: "waiting", label: "Waiting for you" };
  if (report.waiting === "reporter") return { tone: "waiting", label: "Waiting for the reporter" };
  if (report.fix) {
    if (report.fix.state === "missed") return { tone: "bad", label: releaseText(report.fix) };
    return { tone: report.fix.state === "expected" ? "active" : "good", label: releaseText(report.fix) };
  }
  if (report.state === "closed") return { tone: "quiet", label: `Closed${report.stateReason ? ` (${report.stateReason.replace(/_/g, " ")})` : ""}` };
  if (atWork(report)) return { tone: "active", label: `Agent at work${report.stage ? `: ${report.stage}` : ""}` };
  if (decisionOf(report, marks)?.decision === "fix") return { tone: "waiting", label: "No agent yet" };
  return { tone: "quiet", label: "Waiting for triage" };
}

function BugRow({ report, marks, now }: { report: Report; marks: Marks; now: number }) {
  const theme = useHostTheme();
  const dispatch = useCanvasAction();
  const status = bugStatus(report, marks);
  const latest = report.notes[report.notes.length - 1];
  const followUps = report.fix ? report.branches : [];
  const working = report.fix ? [] : report.branches;
  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) 190px", gap: 16, padding: "14px 0", borderBottom: `1px solid ${theme.stroke.tertiary}` }}>
      <Stack gap={10}>
        <Stack gap={3}>
          <Title report={report} />
          <Facts report={report} now={now} />
        </Stack>
        <Track steps={track(report, marks)} />
        {report.waiting && report.why ? <Text size="small" weight="medium">{report.why}</Text> : null}
        {latest ? (
          <Text size="small" tone="secondary">
            {`${latest.text} (${ago(latest.at, now)})`}
          </Text>
        ) : null}
        {working.map((branch) => (
          <div key={branch.branch}>
            <Text size="small" tone="tertiary">
              {`On ${branch.branch}${branch.worktree ? ` (${branch.worktree})` : ""}: ${branch.commits.map((c) => c.short).join(", ")}`}
            </Text>
          </div>
        ))}
        {report.fix ? (
          <Text size="small" tone="tertiary">
            {`On main: ${report.fix.commits.map((c) => c.short).join(", ")}, ${when(report.fix.commits[report.fix.commits.length - 1]?.at)}`}
          </Text>
        ) : null}
        {followUps.map((branch) => (
          <div key={branch.branch}>
            <Text size="small" tone="tertiary">
              {`A follow-up on ${branch.branch}: ${branch.commits.map((c) => `${c.short} ${c.subject}`).join("; ")}`}
            </Text>
          </div>
        ))}
        {report.reply?.url ? (
          <Text size="small" tone="tertiary">
            <Link href={report.reply.url}>The reply</Link>
            {report.reply.release ? ` says it comes in ${report.reply.release}` : ""}
            {report.out?.url ? (
              <>
                {"; "}
                <Link href={report.out.url}>told it's out</Link>
              </>
            ) : null}
          </Text>
        ) : null}
      </Stack>
      <Stack gap={8}>
        <Status tone={status.tone} label={status.label} />
        {report.agent?.chat ? (
          <div>
            <Button variant="secondary" onClick={() => dispatch({ type: "openAgent", agentId: report.agent?.chat ?? "" })}>
              Open its chat
            </Button>
          </div>
        ) : null}
        {report.agent && !report.agent.chat ? (
          <Text size="small" tone="tertiary">
            Its chat wasn't recorded.
          </Text>
        ) : null}
      </Stack>
    </div>
  );
}

function BugsTab({ now, marks }: { now: number; marks: Marks }) {
  const bugs = DATA.reports.filter((report) => isBug(report, marks) && !waitsForTriage(report, marks));
  const rank = (report: Report) =>
    report.waiting ? 0 : atWork(report) && !report.fix ? 1 : decisionOf(report, marks)?.decision === "fix" && !report.agent && report.state === "open" ? 2 : landedForUpcoming(report) ? 3 : report.fix ? 4 : 5;
  const sorted = [...bugs].sort((a, b) => rank(a) - rank(b) || b.number - a.number);
  const groups: { title: string; members: Report[] }[] = [
    { title: "Waiting on you or the reporter", members: sorted.filter((r) => rank(r) === 0) },
    { title: "Agents at work", members: sorted.filter((r) => rank(r) === 1 || rank(r) === 2) },
    { title: `On main, for ${upcoming()}`, members: sorted.filter((r) => rank(r) === 3) },
    { title: "Out", members: sorted.filter((r) => rank(r) === 4) },
    { title: "Closed without a fix", members: sorted.filter((r) => rank(r) === 5) },
  ];
  return (
    <Stack gap={22}>
      {groups
        .filter((group) => group.members.length > 0)
        .map((group) => (
          <div key={group.title}>
            <Stack gap={0}>
              <H3>{`${group.title} (${group.members.length})`}</H3>
              {group.members.map((report) => (
                <div key={report.number}>
                  <BugRow report={report} marks={marks} now={now} />
                </div>
              ))}
            </Stack>
          </div>
        ))}
    </Stack>
  );
}

// ---------------------------------------------------------------- suggestions

function SuggestionsTab({ now, marks }: { now: number; marks: Marks }) {
  const ideas = DATA.reports.filter((report) => (report.kind === "idea" || report.kind === "question") && !report.fix);
  const waiting = ideas.filter((report) => waitsForTriage(report, marks));
  const decided = ideas.filter((report) => !waitsForTriage(report, marks));
  const verdict = (report: Report): { tone: Tone; label: string } => {
    const decision = decisionOf(report, marks);
    if (report.tracked) return { tone: "good", label: `Tracked as ${report.tracked}` };
    if (!decision) return { tone: "waiting", label: "Waiting for you" };
    if (!decision.applied && report.state === "open") return { tone: "waiting", label: `${decision.decision}: waits to be applied` };
    if (decision.decision === "reject") return { tone: "quiet", label: "Rejected" };
    if (decision.decision === "answer") return { tone: report.state === "closed" ? "good" : "active", label: report.state === "closed" ? "Answered" : "Being answered" };
    return { tone: "quiet", label: decision.decision };
  };
  return (
    <Stack gap={22}>
      {waiting.length > 0 && (
        <Stack gap={8}>
          <H3>{`Waiting for your decision (${waiting.length})`}</H3>
          <Text size="small" tone="secondary">
            Decide them on the Triage tab, where each shows the reporter's words and the room's proposal.
          </Text>
          {waiting.map((report) => (
            <div key={report.number}>
              <Stack gap={2}>
                <Title report={report} />
                <Text size="small" tone="secondary">
                  {report.proposal ? `Proposal: ${report.proposal.kind} ${report.proposal.id ?? ""}${report.proposal.phase ? `, ${report.proposal.phase}` : ""}` : "No proposal yet: Refresh asks an agent for one."}
                </Text>
              </Stack>
            </div>
          ))}
        </Stack>
      )}
      {decided.length > 0 && (
        <Table
          headers={["Report", "Kind", "Filed", "Where it went", "Why"]}
          rows={decided.map((report) => {
            const decision = decisionOf(report, marks);
            const status = verdict(report);
            return [
              <Link key={report.number} href={report.url}>{`#${report.number} ${report.title}`}</Link>,
              KIND_LABEL[report.kind],
              when(report.opened),
              <Status key="s" tone={status.tone} label={status.label} />,
              decision?.reason ?? "",
            ];
          })}
          striped
        />
      )}
      {ideas.length === 0 ? (
        <Text tone="secondary">No suggestions or questions yet.</Text>
      ) : (
        <Text size="small" tone="tertiary">
          {`${ideas.length} suggestions and questions so far, ${ago(ideas[ideas.length - 1].opened, now)} for the first.`}
        </Text>
      )}
    </Stack>
  );
}

// ---------------------------------------------------------------- released

function ReleasedTab() {
  const fixed = DATA.reports.filter((report) => report.fix);
  const coming = fixed.filter(landedForUpcoming);
  const byVersion = new Map<string, Report[]>();
  for (const report of fixed.filter((r) => !landedForUpcoming(r))) {
    const key = report.fix?.state === "live" ? "Outside the app, out once on main" : `Redlamp ${report.fix?.version}`;
    byVersion.set(key, [...(byVersion.get(key) ?? []), report]);
  }
  const rows = (reports: Report[]) =>
    reports.map((report) => [
      <Link key={report.number} href={report.url}>{`#${report.number} ${report.title}`}</Link>,
      report.fix?.commits.map((c) => c.short).join(", ") ?? "",
      report.reply ? (report.reply.url ? <Link key="r" href={report.reply.url}>Replied</Link> : "Replied") : "Not yet",
      report.fix?.state === "expected" || report.fix?.state === "missed" ? "When it ships" : report.out ? <Link key="o" href={report.out.url}>Told</Link> : "Not yet",
    ]);
  return (
    <Stack gap={22}>
      {coming.length > 0 && (
        <Stack gap={8}>
          <H3>{`Coming in ${upcoming()} (${coming.length})`}</H3>
          <Table headers={["Report", "Commits", "Reply", "Told it's out"]} rows={rows(coming)} striped />
        </Stack>
      )}
      {[...byVersion.entries()].map(([version, reports]) => (
        <div key={version}>
          <Stack gap={8}>
            <H3>{version}</H3>
            <Table headers={["Report", "Commits", "Reply", "Told it's out"]} rows={rows(reports)} striped />
          </Stack>
        </div>
      ))}
    </Stack>
  );
}

// ---------------------------------------------------------------- log, decisions, the room

function LogEntries({ entries, now }: { entries: { at: string; text: string }[]; now: number }) {
  return (
    <Stack gap={10}>
      {entries.map((entry, index) => (
        <div key={`${entry.at}-${index}`} style={{ display: "grid", gridTemplateColumns: "112px minmax(0, 1fr)", gap: 10 }}>
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

export default function ReportsRoom() {
  const now = useNow();
  const dispatch = useCanvasAction();
  const [marks, setMarks] = useCanvasState<Marks>("triage", {});
  const [reasons, setReasons] = useCanvasState<Record<string, string>>("reasons", {});
  const waiting = DATA.reports.filter((report) => waitsForTriage(report, marks));
  const toApply = DATA.reports.filter((report) => waitsToBeApplied(report, marks));
  const waitingOnYou = DATA.reports.filter((report) => report.waiting === "you" && report.state === "open");
  const working = DATA.reports.filter(atWork);
  const coming = DATA.reports.filter(landedForUpcoming);
  const open = DATA.reports.filter((report) => report.state === "open");
  const forYou = waiting.length + toApply.length + waitingOnYou.length;
  const shown: Record<Tab, boolean> = {
    Triage: waiting.length + toApply.length > 0 || DATA.reports.some((r) => decisionOf(r, marks)?.decision === "fix" && !r.agent && r.state === "open"),
    Bugs: DATA.reports.some((report) => isBug(report, marks) && !waitsForTriage(report, marks)),
    Suggestions: DATA.reports.some((report) => report.kind === "idea" || report.kind === "question"),
    Released: DATA.reports.some((report) => report.fix),
    Log: DATA.log.length > 0,
    Decisions: room.decisions.length > 0,
  };
  const tabs = TABS.filter((tab) => shown[tab]);
  const [selected, setSelected] = useCanvasState<Tab>("tab", "Triage");
  const tab: Tab = shown[selected] ? selected : (tabs[0] ?? "Triage");
  const rel = DATA.release;
  return (
    <Stack gap={18} style={{ padding: 4 }}>
      <Stack gap={6}>
        <Row gap={10} align="center">
          <H1>Reports room</H1>
          {forYou > 0 ? <Pill>{`${forYou} waiting for you`}</Pill> : null}
          <Spacer />
          <Button
            variant="ghost"
            onClick={() =>
              dispatch({
                type: "newComposerChat",
                userPrompt: `Bring the reports room up to date: follow ${SKILL} (Every time), write a short read of each report waiting for triage and a proposal for each suggestion, then sync the room.`,
              })
            }
          >
            Refresh
          </Button>
        </Row>
        <Text tone="secondary">
          Reports from Redlamp's Report a Bug and Send Feedback, and issues people file on GitHub. Each bug goes from your triage to its own agent, a fix on main and a release; each suggestion waits for your decision.
        </Text>
        <Text size="small" tone="secondary">
          {[
            rel.latest ? `Latest release ${rel.latest.version} (${rel.latest.date})` : null,
            rel.upcoming ? `upcoming ${rel.upcoming}${rel.stage && rel.roomVersion === rel.upcoming ? `, ${rel.stage} in the release room` : ""}` : null,
          ]
            .filter(Boolean)
            .join("; ")}
        </Text>
        <Text size="small" tone="tertiary">
          {`Checked ${ago(DATA.checked, now)} (${when(DATA.checked)}); last change ${ago(DATA.changed, now)}.`}
        </Text>
      </Stack>

      <Row gap={32} wrap>
        <Stat value={`${forYou}`} label="Waiting for you" tone={forYou ? "warning" : undefined} />
        <Stat value={`${working.length}`} label="Agents at work" />
        <Stat value={`${coming.length}`} label={`Fixed on main, for ${upcoming()}`} />
        <Stat value={`${open.length}`} label="Open reports" />
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

      {tab === "Triage" && <TriageTab now={now} marks={marks} setMarks={setMarks} reasons={reasons} setReasons={setReasons} />}
      {tab === "Bugs" && <BugsTab now={now} marks={marks} />}
      {tab === "Suggestions" && <SuggestionsTab now={now} marks={marks} />}
      {tab === "Released" && <ReleasedTab />}
      {tab === "Log" && <LogEntries entries={DATA.log} now={now} />}
      {tab === "Decisions" && (
        <Table headers={["Date", "Decision", "Why", "By"]} rows={room.decisions.map((d) => [d.date, d.decision, d.why, d.by])} striped />
      )}
      {waitingOnYou.length > 0 && tab !== "Bugs" ? (
        <Stack gap={6}>
          <Divider />
          <H2>Agents waiting for you</H2>
          {waitingOnYou.map((report) => (
            <div key={report.number}>
              <Row gap={8} align="center">
                <Title report={report} />
                <Spacer />
                {report.agent?.chat ? (
                  <Button variant="secondary" onClick={() => dispatch({ type: "openAgent", agentId: report.agent?.chat ?? "" })}>
                    Open its chat
                  </Button>
                ) : null}
              </Row>
              {report.why ? (
                <Text size="small" tone="secondary">
                  {report.why}
                </Text>
              ) : null}
            </div>
          ))}
        </Stack>
      ) : null}
      {room.links.length > 0 && (
        <Text size="small" tone="tertiary">
          {room.links.map((link) => `${link.label}: ${link.target}`).join(" · ")}
        </Text>
      )}
      <CollapsibleSection title="How this room works">
        <Text size="small" tone="secondary">
          {`room.py sync writes this board from GitHub, git and the room's notes (${DATA.notesDir}); room.py watch keeps it current every 5 minutes. Fix it opens a chat for that bug alone, which follows ${BRIEF}. Accept, Reject and Close are recorded here; Apply decisions opens one chat that carries them out. Your clicks stay in this canvas's data file.`}
        </Text>
      </CollapsibleSection>
    </Stack>
  );
}
