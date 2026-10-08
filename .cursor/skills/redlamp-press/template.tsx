import {
  BarChart,
  Button,
  Checkbox,
  CollapsibleSection,
  Divider,
  Grid,
  H1,
  H2,
  H3,
  Link,
  Pill,
  Row,
  Select,
  Spacer,
  Stack,
  Stat,
  Table,
  Text,
  TextArea,
  TextInput,
  useCanvasAction,
  useCanvasState,
  useEffect,
  useHostTheme,
  useMemo,
  useState,
} from "cursor/canvas";
import type { CanvasHostTheme, ChartSeries, Color, StatTone } from "cursor/canvas";

// The press room (.cursor/skills/redlamp-press/SKILL.md): every outlet Redlamp is pitched to, from
// finding it to its coverage. A workstream's canvas (.cursor/skills/workstream-canvas/SKILL.md) with
// the outreach tracker added. Edit `workstream` and the DATA block; DATA must stay strict JSON, since
// the outreach script parses it, rewrites GMAIL, LOGGED and PRS, and reads the statuses and waves set
// here from the canvas's data file. Contacts, pitches and replies never go into the repository: this
// template holds none, only one example outlet at example.com to show the shape.

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
  title: "Press and newsletter outreach",
  goal: "Put Redlamp in front of the newsletters, sites and communities that cover Mac software, photography and open source, one personal pitch at a time, and track every pitch from draft to reply.",
  status: "Not started.",
  updated: "2026-10-08T00:00:00+01:00",
  stats: [],
  needsYou: [],
  ready: [],
  blocked: [],
  plan: [],
  log: [],
  decisions: [],
  measurements: [],
  links: [{ label: "The press room's skill", target: ".cursor/skills/redlamp-press/SKILL.md" }],
};

// ---------------------------------------------------------------- outreach data

type Wave = "now" | "write-up" | "beta";
type Route = "email" | "form" | "post" | "pr" | "listing";
type Priority = "A" | "B" | "C";
type Group = "Communities" | "Lists and directories" | "Apple developers" | "Developers" | "Agents and AI" | "Mac press" | "Photography";

interface Outlet {
  id: string;
  name: string;
  group: Group;
  kind: string;
  url: string;
  route: Route;
  to?: string[];
  link?: string;
  greet?: string;
  pitch?: string;
  hook?: string;
  title?: string;
  text?: string;
  /** What to do, for rows that aren't emails ("Open a pull request"). */
  action?: string;
  wave: Wave;
  priority: Priority;
  needs?: "agents" | "tech";
  why: string;
  note?: string;
  source: string;
  chat?: string;
}

interface Template {
  lang: "en" | "pt";
  use: string;
  subject: string;
  body: string;
}

interface OutreachData {
  checked: string;
  me: string;
  templates: Record<string, Template>;
  blurb: string;
  outlets: Outlet[];
  leftOut: { name: string; why: string }[];
}

interface GmailThread {
  draftId?: string;
  threadId: string;
  state: "draft" | "sent" | "replied" | "gone";
  draftedAt?: string;
  sentAt?: string;
  replyAt?: string;
  replyFrom?: string;
}

interface GmailSync {
  updated: string | null;
  threads: Record<string, GmailThread>;
}

const DATA: OutreachData = /*OUTREACH-DATA:BEGIN*/ {
 "checked": "",
 "me": "",
 "templates": {
  "mac": {
   "lang": "en",
   "use": "Mac news and app sites",
   "subject": "Redlamp, a free and open-source raw editor for the Mac",
   "body": "{greeting}\n\n{hook}\n\nA short paragraph on what Redlamp is, in the owner's voice, and a link to try it.\n\nThanks for reading,\n"
  }
 },
 "blurb": "",
 "outlets": [
  {
   "id": "example-weekly",
   "name": "Example Weekly",
   "group": "Mac press",
   "kind": "Weekly newsletter",
   "url": "https://example.com",
   "route": "email",
   "to": [
    "editor@example.com"
   ],
   "greet": "Hi,",
   "pitch": "mac",
   "hook": "One sentence on why this outlet's readers would care.",
   "wave": "now",
   "priority": "B",
   "why": "Why the outlet is on the list.",
   "source": "Where its address came from: the outlet's own contact page."
  }
 ],
 "leftOut": []
} /*OUTREACH-DATA:END*/;

const GMAIL: GmailSync = /*GMAIL-SYNC:BEGIN*/ { "updated": null, "threads": {} } /*GMAIL-SYNC:END*/;

const STATUSES = ["To do", "Drafted", "Sent", "Followed up", "Replied", "Scheduled", "Covered", "Declined", "No reply", "Skipped"] as const;
type Status = (typeof STATUSES)[number];
const RANK: Record<Status, number> = {
  "To do": 0,
  Drafted: 1,
  Sent: 2,
  "Followed up": 3,
  Replied: 4,
  Scheduled: 5,
  Covered: 6,
  Declined: 6,
  "No reply": 6,
  Skipped: 6,
};
const FINAL: Status[] = ["Covered", "Declined", "No reply", "Skipped"];

const WAVES: { id: Wave; label: string; intro: string }[] = [
  {
    id: "now",
    label: "Now",
    intro:
      "Everything that can go out this week: communities, lists and directories, developer newsletters, bloggers, and the Mac and photography press, pitched as a pre-alpha that wants testers.",
  },
  {
    id: "write-up",
    label: "With the write-ups",
    intro: "Outlets that need something to read first. Their Compose links unlock when the write-ups' URLs are filled in above.",
  },
  {
    id: "beta",
    label: "Later",
    intro:
      "Rows that wait for something specific: Homebrew's age and star rules, a Product Hunt day saved for a later release, and an improved X-Trans demosaic before the Fuji outlets. Move any row sooner in its details.",
  },
];

const GROUPS: Group[] = ["Communities", "Lists and directories", "Apple developers", "Developers", "Agents and AI", "Mac press", "Photography"];
const ROUTE_LABEL: Record<Route, string> = { email: "Email", form: "Form", post: "Post", pr: "Pull request", listing: "Listing" };
const ACTION_LABEL: Record<Exclude<Route, "email">, string> = { form: "Open form", post: "Open", pr: "Edit list", listing: "Submit" };

interface Writeups {
  agentsUrl: string;
  techTitle: string;
  techUrl: string;
}
const NO_WRITEUPS: Writeups = { agentsUrl: "", techTitle: "", techUrl: "" };

interface Filters {
  q: string;
  group: string;
  wave: string;
  status: string;
  route: string;
}
const NO_FILTERS: Filters = { q: "", group: "all", wave: "all", status: "all", route: "all" };

const DAY = 86400000;

interface Reply {
  /** The reply's date, YYYY-MM-DD. */
  at: string;
  from: string;
  text: string;
  link: string;
  next: string;
}
const NO_REPLY: Reply = { at: "", from: "", text: "", link: "", next: "" };
const OUTCOMES: Status[] = ["Sent", "Followed up", "Replied", "Scheduled", "Covered", "Declined", "No reply"];
const ANSWERED: Status[] = ["Replied", "Scheduled", "Covered", "Declined"];

/** A coverage link counts only once it's a real address; "TBD" and the like stay as notes. */
function isUrl(text: string): boolean {
  return /^https?:\/\/\S+$/i.test(text.trim());
}

function today(): string {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function hasReply(reply: Reply | undefined): boolean {
  return !!reply && (reply.text !== "" || reply.link !== "" || reply.from !== "");
}

/**
 * What the owner reported in chat (sends and replies), recorded by an agent: strict JSON, read by outreach.py too.
 * A reply edited in the canvas replaces its logged one; a logged status counts whenever it ranks above the canvas's own.
 */
const LOGGED: Record<string, { status: Status; sentAt?: string; url?: string; reply?: Reply }> = /*LOGGED:BEGIN*/ {} /*LOGGED:END*/;

interface PullRequest {
  url: string;
  repo: string;
  number: number;
  state: "open" | "merged" | "closed";
  openedAt: string;
  mergedAt?: string;
  closedAt?: string;
  /** GitHub's review decision: APPROVED, CHANGES_REQUESTED or REVIEW_REQUIRED. */
  review?: string;
  checks?: "passing" | "failing" | "pending" | "";
  comments?: number;
  lastComment?: { author: string; at: string; text: string };
  checkedAt?: string;
}

/** The pull requests behind "pr" rows: strict JSON, refreshed by `outreach prs`. Merged counts as Covered, closed as Declined. */
const PRS: Record<string, PullRequest> = /*PRS:BEGIN*/ {} /*PRS:END*/;

function prStatus(pr: PullRequest | undefined): Status | undefined {
  if (!pr) return undefined;
  return pr.state === "merged" ? "Covered" : pr.state === "closed" ? "Declined" : "Sent";
}

function prLabel(pr: PullRequest): string {
  const state = pr.state === "open" ? (pr.review === "CHANGES_REQUESTED" ? "changes requested" : "open") : pr.state;
  const checks = pr.state === "open" && pr.checks === "failing" ? ", checks failing" : "";
  return `#${pr.number} · ${state}${checks}`;
}

/** What a pull request's outcome or latest comment says, shown as its reply when none is logged. */
function prReply(pr: PullRequest | undefined): Reply | undefined {
  if (!pr) return undefined;
  const parts: string[] = [];
  if (pr.state === "merged") parts.push(`Merged ${day(pr.mergedAt)}.`);
  else if (pr.state === "closed") parts.push(`Closed without merging ${day(pr.closedAt)}.`);
  else if (pr.review === "CHANGES_REQUESTED") parts.push("Changes requested.");
  if (pr.lastComment) parts.push(`${pr.lastComment.author}: ${pr.lastComment.text}`);
  if (parts.length === 0) return undefined;
  return {
    at: (pr.mergedAt ?? pr.closedAt ?? pr.lastComment?.at ?? "").slice(0, 10),
    from: pr.lastComment?.author ?? "",
    text: parts.join(" "),
    link: pr.state === "merged" ? pr.url : "",
    next: pr.state === "open" && pr.review === "CHANGES_REQUESTED" ? "Make the requested changes on the add-redlamp branch" : "",
  };
}

function placeholders(line: string): string[] {
  return (line.match(/\{(\w+)\}/g) ?? []).map((token) => token.slice(1, -1));
}

/** Lines whose placeholders are empty are dropped, as `fill` does in outreach.py. */
function fill(text: string, vars: Record<string, string>): string {
  return text
    .split("\n")
    .filter((line) => placeholders(line).every((key) => (vars[key] ?? "") !== ""))
    .map((line) => line.replace(/\{(\w+)\}/g, (_match: string, key: string) => vars[key] ?? ""))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function needsMet(outlet: Outlet, writeups: Writeups): boolean {
  if (outlet.needs === "agents") return writeups.agentsUrl.trim() !== "";
  if (outlet.needs === "tech") return writeups.techTitle.trim() !== "" && writeups.techUrl.trim() !== "";
  return true;
}

function pitchOf(outlet: Outlet, writeups: Writeups): { subject: string; body: string } {
  const template = outlet.pitch ? DATA.templates[outlet.pitch] : undefined;
  if (!template) return { subject: outlet.title ?? "", body: outlet.text ?? "" };
  const greeting =
    template.lang === "pt" ? (outlet.greet ? `Olá ${outlet.greet},` : "Olá,") : outlet.greet ? `Hi ${outlet.greet},` : "Hello,";
  const vars: Record<string, string> = {
    greeting,
    hook: outlet.hook ?? "",
    agentsUrl: writeups.agentsUrl.trim(),
    techTitle: writeups.techTitle.trim(),
    techUrl: writeups.techUrl.trim(),
  };
  return { subject: fill(template.subject, vars), body: fill(template.body, vars) };
}

function composeUrl(outlet: Outlet, subject: string, body: string): string {
  const params = [
    `authuser=${encodeURIComponent(DATA.me)}`,
    "view=cm",
    "fs=1",
    "tf=1",
    `to=${encodeURIComponent((outlet.to ?? []).join(","))}`,
    `su=${encodeURIComponent(subject)}`,
    `body=${encodeURIComponent(body)}`,
  ];
  return `https://mail.google.com/mail/?${params.join("&")}`;
}

function derivedStatus(thread: GmailThread | undefined): Status | undefined {
  if (!thread) return undefined;
  if (thread.state === "replied") return "Replied";
  if (thread.state === "sent") return "Sent";
  if (thread.state === "draft") return "Drafted";
  return undefined;
}

function statusOf(manual: Status | undefined, thread: GmailThread | undefined, ...others: (Status | undefined)[]): Status {
  if (manual && FINAL.includes(manual)) return manual;
  const candidates: Status[] = [manual ?? "To do", derivedStatus(thread) ?? "To do", ...others.map((status) => status ?? "To do")];
  return candidates.reduce((best, status) => (RANK[status] > RANK[best] ? status : best));
}

function host(url: string): string {
  try {
    return new URL(url).host.replace(/^www\./, "");
  } catch {
    return url;
  }
}

function day(iso: string | undefined): string {
  if (!iso) return "";
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleDateString(undefined, { day: "numeric", month: "short" });
}

function gmailLine(thread: GmailThread): string {
  if (thread.state === "replied") return `Reply${thread.replyFrom ? ` from ${thread.replyFrom}` : ""} on ${day(thread.replyAt)}; sent ${day(thread.sentAt)}`;
  if (thread.state === "sent") return `Sent ${day(thread.sentAt)}, no reply yet`;
  if (thread.state === "draft") return `Draft in Gmail since ${day(thread.draftedAt)}`;
  return "The draft was deleted without being sent";
}

interface Model {
  outlet: Outlet;
  status: Status;
  wave: Wave;
  thread?: GmailThread;
  sentAt?: string;
  reply?: Reply;
  pr?: PullRequest;
  /** Where a post went live, when it's been logged. */
  postUrl?: string;
  /** A pitch sent over a week ago with no answer. */
  due: boolean;
  /** Followed up over a week ago with no answer. */
  stale: boolean;
  ready: boolean;
  subject: string;
  body: string;
}

const PRIORITY_ORDER: Record<Priority, number> = { A: 0, B: 1, C: 2 };

function buildModels(
  status: Record<string, Status>,
  statusAt: Record<string, string>,
  sentAtMap: Record<string, string>,
  replies: Record<string, Reply>,
  waves: Record<string, Wave>,
  writeups: Writeups,
  now: number,
): Model[] {
  return DATA.outlets
    .map((outlet) => {
      const thread = GMAIL.threads[outlet.id];
      const logged = LOGGED[outlet.id];
      const pr = PRS[outlet.id];
      const current = statusOf(status[outlet.id], thread, logged?.status, prStatus(pr));
      const sentAt =
        thread?.sentAt ??
        sentAtMap[outlet.id] ??
        logged?.sentAt ??
        pr?.openedAt ??
        (current === "Sent" ? statusAt[outlet.id] : undefined);
      const sentTime = sentAt ? Date.parse(sentAt) : Number.NaN;
      const changedTime = statusAt[outlet.id] ? Date.parse(statusAt[outlet.id]) : Number.NaN;
      const pitched = outlet.route === "email";
      const { subject, body } = pitchOf(outlet, writeups);
      return {
        outlet,
        status: current,
        wave: waves[outlet.id] ?? outlet.wave,
        thread,
        sentAt,
        reply: replies[outlet.id] ?? logged?.reply ?? prReply(pr),
        pr,
        postUrl: logged?.url,
        stale: pitched && current === "Followed up" && !Number.isNaN(changedTime) && now - changedTime > 7 * DAY,
        due: pitched && current === "Sent" && !Number.isNaN(sentTime) && now - sentTime > 7 * DAY,
        ready: needsMet(outlet, writeups),
        subject,
        body,
      };
    })
    .sort(
      (a, b) =>
        PRIORITY_ORDER[a.outlet.priority] - PRIORITY_ORDER[b.outlet.priority] ||
        GROUPS.indexOf(a.outlet.group) - GROUPS.indexOf(b.outlet.group) ||
        a.outlet.name.localeCompare(b.outlet.name),
    );
}

function useModels(now: number): Model[] {
  const [status] = useCanvasState<Record<string, Status>>("status", {});
  const [statusAt] = useCanvasState<Record<string, string>>("statusAt", {});
  const [sentAt] = useCanvasState<Record<string, string>>("sentAt", {});
  const [replies] = useCanvasState<Record<string, Reply>>("replies", {});
  const [waves] = useCanvasState<Record<string, Wave>>("waves", {});
  const [writeups] = useCanvasState<Writeups>("writeups", NO_WRITEUPS);
  return useMemo(
    () => buildModels(status, statusAt, sentAt, replies, waves, writeups, now),
    [status, statusAt, sentAt, replies, waves, writeups, now],
  );
}

const ROUTE_ACTION: Record<Exclude<Route, "email">, string> = {
  form: "Send the form",
  post: "Post",
  pr: "Open a pull request",
  listing: "Submit the listing",
};

function actionOf(outlet: Outlet): string {
  return outlet.action ?? (outlet.route === "email" ? "Send the email" : ROUTE_ACTION[outlet.route]);
}

function isDone(status: Status): boolean {
  return RANK[status] >= RANK.Sent && status !== "Skipped";
}

/**
 * One status per outlet: the Emails, Actions, Replies and Outlets tabs all read and write it. `sentAt` keeps the
 * first time an outlet was marked sent, so later outcomes (Followed up, Replied) don't lose it.
 */
function useSetStatus(): (id: string, status: Status | undefined) => void {
  const [current, setStatus] = useCanvasState<Record<string, Status>>("status", {});
  const [changedAt, setStatusAt] = useCanvasState<Record<string, string>>("statusAt", {});
  const [sentAt, setSentAt] = useCanvasState<Record<string, string>>("sentAt", {});
  return (id, status) => {
    const now = new Date().toISOString();
    const previous = current[id];
    const firstSent = sentAt[id] ?? (previous && isDone(previous) ? changedAt[id] : undefined);
    setStatus((prev) => {
      const next = { ...prev };
      if (status) next[id] = status;
      else delete next[id];
      return next;
    });
    setStatusAt((prev) => {
      const next = { ...prev };
      if (status) next[id] = now;
      else delete next[id];
      return next;
    });
    setSentAt((prev) => {
      const next = { ...prev };
      if (status && isDone(status)) next[id] = firstSent ?? now;
      else delete next[id];
      return next;
    });
  };
}

// ---------------------------------------------------------------- rendering (keys sit on wrapper divs)

const TABS = ["Overview", "Emails", "Actions", "Replies", "Outlets", "Pitches", "Plan", "Decisions", "Log", "Measurements"] as const;
type Tab = (typeof TABS)[number];

const STEP_LABEL: Record<StepStatus, string> = {
  done: "Done",
  "in progress": "In progress",
  "not started": "Not started",
  blocked: "Blocked",
  dropped: "Dropped",
};

type DotState = StepStatus | "waiting" | "blocking";

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

/** One hue per kind of status, the same in every tab: grey not started or closed, blue in flight, orange needs a nudge. */
const STATUS_HUE: Record<Status, Color> = {
  "To do": "gray",
  Drafted: "blue",
  Sent: "blue",
  "Followed up": "purple",
  Replied: "cyan",
  Scheduled: "green",
  Covered: "green",
  Declined: "red",
  "No reply": "gray",
  Skipped: "gray",
};

function chipLook(theme: CanvasHostTheme, status: Status, flagged: boolean): { color: string; background: string; borderColor: string } {
  const hue: Color = flagged ? "orange" : STATUS_HUE[status];
  if (hue === "gray") {
    return {
      color: status === "To do" ? theme.text.secondary : theme.text.tertiary,
      background: theme.fill.tertiary,
      borderColor: theme.stroke.tertiary,
    };
  }
  const color = theme.category[hue];
  return { color, background: `color-mix(in srgb, ${color} 16%, transparent)`, borderColor: `color-mix(in srgb, ${color} 40%, transparent)` };
}

function StatusChip({ status, flagged = false, label }: { status: Status; flagged?: boolean; label?: string }) {
  const theme = useHostTheme();
  const look = chipLook(theme, status, flagged);
  return (
    <span
      style={{
        display: "inline-block",
        padding: "1px 8px",
        borderRadius: 999,
        fontSize: 11.5,
        lineHeight: "17px",
        fontWeight: 600,
        color: look.color,
        background: look.background,
        border: `1px solid ${look.borderColor}`,
        whiteSpace: "nowrap",
      }}
    >
      {label ?? (flagged && status === "Sent" ? "Follow-up due" : status)}
    </span>
  );
}

function StatusSelect({ status, flagged, onChange }: { status: Status; flagged: boolean; onChange: (status: Status) => void }) {
  const theme = useHostTheme();
  const look = chipLook(theme, status, flagged);
  return (
    <select
      value={status}
      onChange={(event: { target: { value: string } }) => onChange(event.target.value as Status)}
      style={{
        color: look.color,
        background: look.background,
        border: `1px solid ${look.borderColor}`,
        borderRadius: 999,
        padding: "3px 8px",
        fontSize: 12,
        fontWeight: 600,
        cursor: "pointer",
        maxWidth: "100%",
        colorScheme: theme.kind === "light" ? "light" : "dark",
      }}
    >
      {STATUSES.map((option) => (
        <option key={option} value={option} style={{ background: theme.bg.elevated, color: theme.text.primary }}>
          {flagged && option === "Sent" ? "Sent, follow-up due" : option}
        </option>
      ))}
    </select>
  );
}

const LEGEND: { label: string; status: Status; flagged?: boolean }[] = [
  { label: "To do", status: "To do" },
  { label: "Drafted, Sent", status: "Sent" },
  { label: "Follow-up due", status: "Sent", flagged: true },
  { label: "Followed up", status: "Followed up" },
  { label: "Replied", status: "Replied" },
  { label: "Scheduled, Covered", status: "Covered" },
  { label: "Declined", status: "Declined" },
  { label: "No reply, Skipped", status: "No reply" },
];

function StatusLegend() {
  return (
    <Row gap={6} wrap align="center">
      {LEGEND.map((item) => (
        <span key={item.label}>
          <StatusChip status={item.status} flagged={item.flagged} label={item.label} />
        </span>
      ))}
    </Row>
  );
}

function StatusDot({ status, due }: { status: Status; due: boolean }) {
  const theme = useHostTheme();
  const hue: Color = due ? "orange" : STATUS_HUE[status];
  const color = hue === "gray" ? (status === "To do" ? theme.text.quaternary : theme.text.tertiary) : theme.category[hue];
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

function CopyBlock({ text }: { text: string }) {
  const theme = useHostTheme();
  return (
    <div
      style={{
        fontSize: 12,
        lineHeight: "18px",
        padding: "10px 12px",
        borderRadius: 6,
        background: theme.fill.tertiary,
        color: theme.text.primary,
        whiteSpace: "pre-wrap",
        wordBreak: "break-word",
        userSelect: "all",
      }}
    >
      {text}
    </div>
  );
}

function Plain({ children, tone = "secondary" }: { children: string; tone?: "primary" | "secondary" | "tertiary" }) {
  const theme = useHostTheme();
  return <span style={{ fontSize: 12, lineHeight: "17px", color: theme.text[tone], wordBreak: "break-word" }}>{children}</span>;
}

type Mark = { state: "done" | "skipped" | "asked"; at: string };

function useMarks() {
  return useCanvasState<Record<string, Mark>>("needsYou", {});
}

function settled(item: Workstream["needsYou"][number], marks: Record<string, Mark>): boolean {
  const mark = marks[item.id];
  return item.done || mark?.state === "done" || mark?.state === "skipped";
}

function NeedsYouItem({ item }: { item: Workstream["needsYou"][number] }) {
  const dispatch = useCanvasAction();
  const [marks, setMarks] = useMarks();
  const mark = item.done ? undefined : marks[item.id];
  const isSettled = settled(item, marks);
  const markAs = (state: Mark["state"]) => setMarks((prev) => ({ ...prev, [item.id]: { state, at: new Date().toISOString() } }));
  const unmark = () =>
    setMarks((prev) => {
      const next = { ...prev };
      delete next[item.id];
      return next;
    });
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "14px minmax(0, 1fr)",
        gap: 8,
        alignItems: "start",
        opacity: isSettled ? 0.6 : 1,
      }}
    >
      <div style={{ paddingTop: 6 }}>
        <Dot state={isSettled ? "done" : item.blocking ? "blocking" : "waiting"} />
      </div>
      <Stack gap={3}>
        <Row gap={8} align="center">
          <Text size="small" weight="semibold">
            {item.title}
          </Text>
          {item.blocking && !isSettled ? <Pill size="sm">Blocks work</Pill> : null}
        </Row>
        <Text size="small" tone="secondary">
          {item.detail}
        </Text>
        <Text size="small" tone="tertiary">
          {`Unblocks: ${item.unblocks}`}
        </Text>
        {item.command && !isSettled ? <CommandBlock command={item.command} /> : null}
        {!item.done && (
          <Row gap={6} align="center">
            {mark ? (
              <>
                <Plain tone="tertiary">
                  {`${mark.state === "asked" ? "Given to an agent" : mark.state === "done" ? "Marked done" : "Marked skipped"} ${when(mark.at)}; the next update folds it in.`}
                </Plain>
                <Button variant="ghost" onClick={unmark}>
                  Undo
                </Button>
              </>
            ) : (
              <>
                <Button variant="ghost" onClick={() => markAs("done")}>
                  Done
                </Button>
                <Button variant="ghost" onClick={() => markAs("skipped")}>
                  Skip
                </Button>
                <Button
                  variant="ghost"
                  onClick={() => {
                    markAs("asked");
                    dispatch({
                      type: "newComposerChat",
                      userPrompt: `Take on the Needs you item "${item.title}" (${item.id}) from this canvas: ${item.detail}`,
                    });
                  }}
                >
                  Ask an agent
                </Button>
              </>
            )}
          </Row>
        )}
      </Stack>
    </div>
  );
}

function NeedsYou({ items }: { items: Workstream["needsYou"] }) {
  const [marks] = useMarks();
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
          <NeedsYouItem item={item} />
        </div>
      ))}
      {done.length > 0 && (
        <CollapsibleSection title="Done" count={done.length} defaultOpen={open.length === 0}>
          <Stack gap={10}>
            {done.map((item) => (
              <div key={item.id}>
                <NeedsYouItem item={item} />
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

function OutletAction({ model }: { model: Model }) {
  const outlet = model.outlet;
  if (isDone(model.status)) {
    return <Plain tone="tertiary">{outlet.route === "email" ? "Already sent" : "Done"}</Plain>;
  }
  if (outlet.route === "email") {
    if (!model.ready) {
      return <Plain tone="tertiary">Needs the write-up</Plain>;
    }
    return <Link href={composeUrl(outlet, model.subject, model.body)}>Compose in Gmail</Link>;
  }
  if (!model.ready) {
    return <Plain tone="tertiary">Needs the write-up</Plain>;
  }
  return <Link href={outlet.link ?? outlet.url}>{ACTION_LABEL[outlet.route]}</Link>;
}

const DONE_WORD: Record<Route, string> = { email: "Sent", form: "Sent", post: "Posted", pr: "Opened", listing: "Submitted" };

function contactLine(outlet: Outlet): string {
  if (outlet.route === "email") return (outlet.to ?? []).join(", ");
  const pr = PRS[outlet.id];
  if (pr) return `Pull request ${prLabel(pr)} · ${pr.repo}`;
  const posted = LOGGED[outlet.id]?.url;
  if (posted) return `Your post · ${host(posted)}`;
  return `${ROUTE_LABEL[outlet.route]} · ${host(outlet.link ?? outlet.url)}`;
}

function Detail({ label, children }: { label: string; children: string }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "64px minmax(0, 1fr)", gap: 8 }}>
      <Plain tone="tertiary">{label}</Plain>
      <Plain>{children}</Plain>
    </div>
  );
}

function OutletDetails({ model }: { model: Model }) {
  const dispatch = useCanvasAction();
  const [notes, setNotes] = useCanvasState<Record<string, string>>("notes", {});
  const [waves, setWaves] = useCanvasState<Record<string, Wave>>("waves", {});
  const outlet = model.outlet;
  const chat = outlet.chat;
  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.35fr)", gap: 20, padding: "10px 0 4px 24px" }}>
      <Stack gap={8}>
        <Detail label="Why">{outlet.why}</Detail>
        {outlet.note ? <Detail label="Note">{outlet.note}</Detail> : null}
        {outlet.to ? <Detail label="To">{outlet.to.join(", ")}</Detail> : null}
        {outlet.link ? <Detail label={ROUTE_LABEL[outlet.route]}>{outlet.link}</Detail> : null}
        <Detail label="Source">{outlet.source}</Detail>
        {model.thread ? <Detail label="Gmail">{gmailLine(model.thread)}</Detail> : null}
        {model.due ? <Detail label="Follow up">A week has passed: one short follow-up in the same thread, then No reply.</Detail> : null}
        <Row gap={8} align="center">
          <Plain tone="tertiary">Wave</Plain>
          <Select
            value={waves[outlet.id] ?? outlet.wave}
            options={WAVES.map((wave) => ({ value: wave.id, label: wave.label }))}
            onChange={(value) => setWaves((prev) => ({ ...prev, [outlet.id]: value as Wave }))}
          />
          {waves[outlet.id] && waves[outlet.id] !== outlet.wave ? (
            <Button variant="ghost" onClick={() => setWaves((prev) => ({ ...prev, [outlet.id]: outlet.wave }))}>
              Reset
            </Button>
          ) : null}
        </Row>
        <TextInput
          value={notes[outlet.id] ?? ""}
          placeholder="Notes: who replied, links to coverage"
          onChange={(value) => setNotes((prev) => ({ ...prev, [outlet.id]: value }))}
        />
        {chat ? (
          <Row>
            <Button variant="secondary" onClick={() => dispatch({ type: "openAgent", agentId: chat })}>
              Open the earlier chat
            </Button>
          </Row>
        ) : null}
      </Stack>
      <Stack gap={6}>
        {model.subject ? (
          <Plain tone="primary">{outlet.route === "email" || outlet.route === "form" ? `Subject: ${model.subject}` : model.subject}</Plain>
        ) : null}
        {model.body ? <CopyBlock text={model.body} /> : null}
        {!model.ready ? <Plain tone="tertiary">Fill in the write-up URLs at the top of Outlets to complete this pitch.</Plain> : null}
      </Stack>
    </div>
  );
}

function OutletRow({ model, open, onToggle }: { model: Model; open: boolean; onToggle: () => void }) {
  const theme = useHostTheme();
  const setStatusFor = useSetStatus();
  const outlet = model.outlet;
  return (
    <div style={{ borderBottom: `1px solid ${theme.stroke.tertiary}`, padding: "7px 0" }}>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "14px minmax(0, 2fr) minmax(0, 1.6fr) 124px 168px",
          gap: 10,
          alignItems: "center",
          opacity: model.status === "Skipped" ? 0.55 : 1,
        }}
      >
        <StatusDot status={model.status} due={model.due} />
        <Stack gap={1}>
          <Row gap={6} align="center">
            <Link href={outlet.url}>{outlet.name}</Link>
            <Pill size="sm">{outlet.priority}</Pill>
          </Row>
          <Plain tone="tertiary">{`${outlet.group} · ${outlet.kind}`}</Plain>
        </Stack>
        <Plain>{contactLine(outlet)}</Plain>
        <StatusSelect status={model.status} flagged={model.due || model.stale} onChange={(status) => setStatusFor(outlet.id, status)} />
        <Row gap={8} align="center">
          <OutletAction model={model} />
          <Spacer />
          <Button variant="ghost" onClick={onToggle}>
            {open ? "Hide" : "Details"}
          </Button>
        </Row>
      </div>
      {open ? <OutletDetails model={model} /> : null}
    </div>
  );
}

function LabeledInput({ label, value, placeholder, onChange }: { label: string; value: string; placeholder: string; onChange: (value: string) => void }) {
  return (
    <Stack gap={4}>
      <Plain tone="tertiary">{label}</Plain>
      <TextInput value={value} placeholder={placeholder} onChange={onChange} />
    </Stack>
  );
}

function OutletsTab({ now }: { now: number }) {
  const theme = useHostTheme();
  const models = useModels(now);
  const [writeups, setWriteups] = useCanvasState<Writeups>("writeups", NO_WRITEUPS);
  const [filters, setFilters] = useCanvasState<Filters>("filters", NO_FILTERS);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const query = filters.q.trim().toLowerCase();
  const visible = models.filter(
    (model) =>
      (filters.group === "all" || model.outlet.group === filters.group) &&
      (filters.wave === "all" || model.wave === filters.wave) &&
      (filters.status === "all" || model.status === filters.status) &&
      (filters.route === "all" || model.outlet.route === filters.route) &&
      (query === "" ||
        `${model.outlet.name} ${model.outlet.kind} ${model.outlet.group} ${(model.outlet.to ?? []).join(" ")}`.toLowerCase().includes(query)),
  );
  const set = (patch: Partial<Filters>) => setFilters((prev) => ({ ...prev, ...patch }));
  return (
    <Stack gap={18}>
      <StatusLegend />
      <Grid columns="minmax(0, 1.4fr) repeat(4, minmax(0, 1fr))" gap={10} align="end">
        <LabeledInput label="Search" value={filters.q} placeholder="Name, kind or address" onChange={(q) => set({ q })} />
        <Stack gap={4}>
          <Plain tone="tertiary">Group</Plain>
          <Select
            value={filters.group}
            options={[{ value: "all", label: "All groups" }, ...GROUPS.map((group) => ({ value: group, label: group }))]}
            onChange={(group) => set({ group })}
          />
        </Stack>
        <Stack gap={4}>
          <Plain tone="tertiary">Wave</Plain>
          <Select
            value={filters.wave}
            options={[{ value: "all", label: "All waves" }, ...WAVES.map((wave) => ({ value: wave.id, label: wave.label }))]}
            onChange={(wave) => set({ wave })}
          />
        </Stack>
        <Stack gap={4}>
          <Plain tone="tertiary">Status</Plain>
          <Select
            value={filters.status}
            options={[{ value: "all", label: "Any status" }, ...STATUSES.map((status) => ({ value: status, label: status }))]}
            onChange={(status) => set({ status })}
          />
        </Stack>
        <Stack gap={4}>
          <Plain tone="tertiary">Route</Plain>
          <Select
            value={filters.route}
            options={[
              { value: "all", label: "Any route" },
              ...(Object.keys(ROUTE_LABEL) as Route[]).map((route) => ({ value: route, label: ROUTE_LABEL[route] })),
            ]}
            onChange={(route) => set({ route })}
          />
        </Stack>
      </Grid>

      <Stack gap={8} style={{ padding: 12, borderRadius: 8, background: theme.fill.quaternary }}>
        <Text size="small" weight="semibold">
          Write-ups
        </Text>
        <Grid columns="minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1fr)" gap={10} align="end">
          <LabeledInput
            label="'How Redlamp is built': URL"
            value={writeups.agentsUrl}
            placeholder="https://redlamp.app/blog/…"
            onChange={(agentsUrl) => setWriteups((prev) => ({ ...prev, agentsUrl }))}
          />
          <LabeledInput
            label="Technical post: title"
            value={writeups.techTitle}
            placeholder="How Redlamp's film looks come from datasheets"
            onChange={(techTitle) => setWriteups((prev) => ({ ...prev, techTitle }))}
          />
          <LabeledInput
            label="Technical post: URL"
            value={writeups.techUrl}
            placeholder="https://redlamp.app/blog/…"
            onChange={(techUrl) => setWriteups((prev) => ({ ...prev, techUrl }))}
          />
        </Grid>
      </Stack>

      <Row gap={10} align="center">
        <Text size="small" tone="secondary">
          {`${visible.length} of ${models.length} outlets`}
        </Text>
        <Spacer />
        {(filters.q || filters.group !== "all" || filters.wave !== "all" || filters.status !== "all" || filters.route !== "all") && (
          <Button variant="ghost" onClick={() => setFilters(NO_FILTERS)}>
            Clear filters
          </Button>
        )}
        <Button
          variant="ghost"
          onClick={() => setOpen(Object.fromEntries(visible.map((model) => [model.outlet.id, true])))}
        >
          Expand all
        </Button>
        <Button variant="ghost" onClick={() => setOpen({})}>
          Collapse all
        </Button>
      </Row>

      {WAVES.map((wave) => {
        const rows = visible.filter((model) => model.wave === wave.id);
        if (rows.length === 0) return null;
        const sent = rows.filter((model) => RANK[model.status] >= RANK.Sent && model.status !== "Skipped").length;
        return (
          <div key={wave.id}>
            <Stack gap={8}>
              <Row gap={10} align="center">
                <H2>{wave.label}</H2>
                <Text size="small" tone="tertiary">
                  {`${rows.length} outlets · ${sent} sent`}
                </Text>
              </Row>
              <Text size="small" tone="secondary">
                {wave.intro}
              </Text>
              <div style={{ borderTop: `1px solid ${theme.stroke.tertiary}` }}>
                {rows.map((model) => (
                  <div key={model.outlet.id}>
                    <OutletRow
                      model={model}
                      open={open[model.outlet.id] ?? false}
                      onToggle={() => setOpen((prev) => ({ ...prev, [model.outlet.id]: !prev[model.outlet.id] }))}
                    />
                  </div>
                ))}
              </div>
            </Stack>
          </div>
        );
      })}
      <Text size="small" tone="tertiary">
        {`Outlets checked live on ${DATA.checked}. Addresses are the ones each outlet publishes for tips, reviews or contact. ${
          GMAIL.updated ? `Gmail last synced ${when(GMAIL.updated)}.` : "Gmail isn't connected; tick rows in Emails and Actions, or set statuses here, as you go."
        }`}
      </Text>
    </Stack>
  );
}

const EMAIL_COLUMNS = "24px minmax(0, 1.2fr) minmax(0, 1.3fr) minmax(0, 2fr) 124px 172px";
const ACTION_COLUMNS = "24px minmax(0, 2fr) minmax(0, 1.4fr) 124px 172px";

/** The When column: the status and its date in the status's colour, or nothing for a row still to do. */
function WhenChip({ model, statusAt, doneWord }: { model: Model; statusAt: Record<string, string>; doneWord: string }) {
  const flagged = model.due || model.stale;
  const line = flagged ? (model.due ? "Follow-up due" : "Mark No reply?") : whenLine(model, statusAt, doneWord);
  return line ? (
    <div>
      <StatusChip status={model.status} flagged={flagged} label={line} />
    </div>
  ) : (
    <span />
  );
}
/** Needs-you items that the checklists already track row by row. */
const COVERED_BY_CHECKLISTS = new Set(["send-wave-1"]);

function Address({ children }: { children: string }) {
  const theme = useHostTheme();
  return (
    <span style={{ fontSize: 12, lineHeight: "17px", color: theme.text.primary, wordBreak: "break-all", userSelect: "all" }}>{children}</span>
  );
}

function HeaderCells({ columns, labels }: { columns: string; labels: string[] }) {
  const theme = useHostTheme();
  return (
    <div
      style={{ display: "grid", gridTemplateColumns: columns, gap: 10, padding: "6px 0", borderBottom: `1px solid ${theme.stroke.secondary}` }}
    >
      {labels.map((label, index) => (
        <div key={`${index}-${label}`}>
          <Plain tone="tertiary">{label}</Plain>
        </div>
      ))}
    </div>
  );
}

function SectionRow({ title, done, count, noun }: { title: string; done: number; count: number; noun: string }) {
  return (
    <div style={{ padding: "14px 0 4px" }}>
      <Row gap={8} align="center">
        <Text size="small" weight="semibold">
          {title}
        </Text>
        <Plain tone="tertiary">{`${done} of ${count} ${noun}`}</Plain>
      </Row>
    </div>
  );
}

function whenLine(model: Model, statusAt: Record<string, string>, doneWord: string): string {
  const status = model.status;
  if (status === "To do") return model.ready ? "" : "Waits for the write-up";
  if (status === "Drafted") return "Draft in Gmail";
  const at = ANSWERED.includes(status)
    ? model.reply?.at || model.thread?.replyAt || statusAt[model.outlet.id]
    : status === "Sent"
      ? model.sentAt
      : statusAt[model.outlet.id];
  const word = status === "Sent" ? doneWord : status;
  return at ? `${word} ${day(at)}` : word;
}

type Panel = "draft" | "reply";

function Clamp({ text, tone = "secondary" }: { text: string; tone?: "primary" | "secondary" | "tertiary" }) {
  const theme = useHostTheme();
  return (
    <div
      style={{
        fontSize: 12,
        lineHeight: "17px",
        color: theme.text[tone],
        overflow: "hidden",
        display: "-webkit-box",
        WebkitBoxOrient: "vertical",
        WebkitLineClamp: 2,
        wordBreak: "break-word",
      }}
    >
      {text}
    </div>
  );
}

function ReplyEditor({ model }: { model: Model }) {
  const [replies, setReplies] = useCanvasState<Record<string, Reply>>("replies", {});
  const setStatusFor = useSetStatus();
  const id = model.outlet.id;
  const reply = replies[id] ?? model.reply ?? NO_REPLY;
  const update = (patch: Partial<Reply>) => {
    setReplies((prev) => {
      const next: Reply = { ...NO_REPLY, ...(prev[id] ?? LOGGED[id]?.reply), ...patch };
      if (!("at" in patch) && next.at === "" && (next.text || next.link || next.from)) next.at = today();
      return { ...prev, [id]: next };
    });
    if (patch.link !== undefined && isUrl(patch.link) && !isUrl(reply.link) && model.status !== "Covered") setStatusFor(id, "Covered");
    else if (patch.text && !reply.text && RANK[model.status] < RANK.Replied) setStatusFor(id, "Replied");
  };
  return (
    <div style={{ padding: "4px 0 14px 34px" }}>
      <Stack gap={10}>
        <Grid columns="150px minmax(0, 1fr) minmax(0, 1fr)" gap={10} align="end">
          <Stack gap={4}>
            <Plain tone="tertiary">Outcome</Plain>
            <Select
              value={OUTCOMES.includes(model.status) ? model.status : "Sent"}
              options={OUTCOMES.map((status) => ({ value: status, label: status }))}
              onChange={(value) => setStatusFor(id, value as Status)}
            />
          </Stack>
          <LabeledInput label="Date of the reply" value={reply.at} placeholder={today()} onChange={(at) => update({ at })} />
          <LabeledInput label="From" value={reply.from} placeholder={model.thread?.replyFrom ?? "Who replied"} onChange={(from) => update({ from })} />
        </Grid>
        <Stack gap={4}>
          <Plain tone="tertiary">What they said</Plain>
          <TextArea value={reply.text} rows={3} placeholder="Paste the reply, or sum it up" onChange={(text) => update({ text })} />
        </Stack>
        <Grid columns="minmax(0, 1fr) minmax(0, 1fr)" gap={10} align="end">
          <LabeledInput
            label="Next step"
            value={reply.next}
            placeholder="Send a build to review, follow up after the next release"
            onChange={(next) => update({ next })}
          />
          <LabeledInput
            label="Coverage link"
            value={reply.link}
            placeholder="The article, the merged pull request or the listing"
            onChange={(link) => update({ link })}
          />
        </Grid>
        <Plain tone="tertiary">
          Writing what they said marks it Replied, and pasting a coverage address (https://…) marks it Covered. Scheduled: they&apos;ve agreed to feature
          it, with the date in Next step. Covered: they wrote about it, merged it or listed it.
        </Plain>
      </Stack>
    </div>
  );
}

function ReplyLine({ model }: { model: Model }) {
  const reply = model.reply;
  if (!reply || (!reply.text && !reply.next && !reply.link)) return null;
  const who = reply.from || model.thread?.replyFrom;
  const summary = [reply.text ? `${who ? `${who}: ` : ""}${reply.text}` : "", reply.next ? `Next: ${reply.next}` : ""].filter(Boolean).join(" · ");
  return (
    <div style={{ padding: "0 0 8px 34px" }}>
      <Stack gap={2}>
        {summary ? <Clamp text={summary} /> : null}
        <CoverageLink link={reply.link} />
      </Stack>
    </div>
  );
}

function CoverageLink({ link }: { link: string }) {
  if (!link.trim()) return null;
  return isUrl(link) ? <Link href={link.trim()}>Coverage</Link> : <Plain tone="tertiary">{`Coverage: ${link}`}</Plain>;
}

function DraftPanel({ model }: { model: Model }) {
  const outlet = model.outlet;
  const where = outlet.route === "email" ? `To: ${(outlet.to ?? []).join(", ")}` : `Where: ${outlet.link ?? outlet.url}`;
  return (
    <div style={{ padding: "2px 0 12px 34px" }}>
      <Stack gap={6}>
        <Plain>{where}</Plain>
        {model.subject ? <Plain tone="primary">{`${outlet.route === "post" ? "Title" : "Subject"}: ${model.subject}`}</Plain> : null}
        {model.body ? <CopyBlock text={model.body} /> : null}
        {!model.ready ? <Plain tone="tertiary">Fill in the write-up URLs at the top of Outlets to complete this draft.</Plain> : null}
        {outlet.note ? <Plain tone="tertiary">{outlet.note}</Plain> : null}
      </Stack>
    </div>
  );
}

function EmailRow({ model, panel, onPanel }: { model: Model; panel?: Panel; onPanel: (panel: Panel) => void }) {
  const theme = useHostTheme();
  const setStatusFor = useSetStatus();
  const [statusAt] = useCanvasState<Record<string, string>>("statusAt", {});
  const outlet = model.outlet;
  const done = isDone(model.status);
  return (
    <div style={{ borderBottom: `1px solid ${theme.stroke.tertiary}` }}>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: EMAIL_COLUMNS,
          gap: 10,
          alignItems: "center",
          padding: "7px 0",
          opacity: done || model.status === "Skipped" ? 0.55 : 1,
        }}
      >
        <Checkbox checked={done} onChange={(checked) => setStatusFor(outlet.id, checked ? "Sent" : undefined)} />
        <Stack gap={1}>
          <Link href={outlet.url}>{outlet.name}</Link>
          <Plain tone="tertiary">{`${outlet.priority} · ${outlet.group}`}</Plain>
        </Stack>
        <Address>{(outlet.to ?? []).join(", ")}</Address>
        <Plain>{model.subject || "Its subject comes from the write-up"}</Plain>
        <WhenChip model={model} statusAt={statusAt} doneWord="Sent" />
        <Row gap={8} align="center">
          {done ? (
            <Button variant="ghost" onClick={() => onPanel("reply")}>
              {panel === "reply" ? "Hide" : hasReply(model.reply) ? "Edit reply" : "Log reply"}
            </Button>
          ) : (
            <OutletAction model={model} />
          )}
          <Spacer />
          <Button variant="ghost" onClick={() => onPanel("draft")}>
            {panel === "draft" ? "Hide" : "Draft"}
          </Button>
        </Row>
      </div>
      {panel === "draft" ? <DraftPanel model={model} /> : panel === "reply" ? <ReplyEditor model={model} /> : <ReplyLine model={model} />}
    </div>
  );
}

function EmailsTab({ now }: { now: number }) {
  const models = useModels(now).filter((model) => model.outlet.route === "email");
  const [show, setShow] = useCanvasState<string>("emailsShow", "all");
  const [open, setOpen] = useState<Record<string, Panel | undefined>>({});
  const sent = models.filter((model) => isDone(model.status)).length;
  const answered = models.filter((model) => ANSWERED.includes(model.status)).length;
  const visible = models.filter((model) =>
    show === "todo" ? !isDone(model.status) && model.status !== "Skipped" : show === "done" ? isDone(model.status) : true,
  );
  const allOpen = visible.length > 0 && visible.every((model) => open[model.outlet.id] === "draft");
  const onPanel = (id: string, panel: Panel) => setOpen((prev) => ({ ...prev, [id]: prev[id] === panel ? undefined : panel }));
  return (
    <Stack gap={12}>
      <Row gap={12} align="center" wrap>
        <Text weight="semibold">{`${sent} of ${models.length} sent`}</Text>
        <Plain tone="tertiary">{`${answered} replied`}</Plain>
        <Spacer />
        <Select
          value={show}
          options={[
            { value: "all", label: "All emails" },
            { value: "todo", label: "To send" },
            { value: "done", label: "Sent" },
          ]}
          onChange={setShow}
        />
        <Button
          variant="ghost"
          onClick={() =>
            setOpen(allOpen ? {} : Object.fromEntries(visible.map((model): [string, Panel] => [model.outlet.id, "draft"])))
          }
        >
          {allOpen ? "Hide drafts" : "Show all drafts"}
        </Button>
      </Row>
      <Text size="small" tone="secondary">
        Compose in Gmail opens the email in {DATA.me || "your Gmail account"} with the address, subject and draft filled in. Send it from Gmail, then tick Sent. Once
        it&apos;s sent, Log reply records the outcome and what they said; the Replies tab collects them all.
      </Text>
      <StatusLegend />
      {visible.length > 0 && (
        <div>
          <HeaderCells columns={EMAIL_COLUMNS} labels={["Sent", "Outlet", "Address", "Subject", "When", ""]} />
          {WAVES.map((wave) => {
            const all = models.filter((model) => model.wave === wave.id);
            const rows = visible.filter((model) => model.wave === wave.id);
            if (rows.length === 0) return null;
            return (
              <div key={wave.id}>
                <SectionRow title={wave.label} done={all.filter((model) => isDone(model.status)).length} count={all.length} noun="sent" />
                {rows.map((model) => (
                  <div key={model.outlet.id}>
                    <EmailRow model={model} panel={open[model.outlet.id]} onPanel={(panel) => onPanel(model.outlet.id, panel)} />
                  </div>
                ))}
              </div>
            );
          })}
        </div>
      )}
    </Stack>
  );
}

function ActionRow({ model, panel, onPanel }: { model: Model; panel?: Panel; onPanel: (panel: Panel) => void }) {
  const theme = useHostTheme();
  const setStatusFor = useSetStatus();
  const [statusAt] = useCanvasState<Record<string, string>>("statusAt", {});
  const outlet = model.outlet;
  const done = isDone(model.status);
  return (
    <div style={{ borderBottom: `1px solid ${theme.stroke.tertiary}` }}>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: ACTION_COLUMNS,
          gap: 10,
          alignItems: "center",
          padding: "7px 0",
          opacity: done || model.status === "Skipped" ? 0.55 : 1,
        }}
      >
        <Checkbox checked={done} onChange={(checked) => setStatusFor(outlet.id, checked ? "Sent" : undefined)} />
        <Stack gap={1}>
          <Text size="small" weight="medium">
            {actionOf(outlet)}
          </Text>
          <Row gap={6} align="center">
            <Link href={outlet.url}>{outlet.name}</Link>
            <Plain tone="tertiary">{`${outlet.priority} · ${outlet.group}`}</Plain>
          </Row>
        </Stack>
        {model.pr ? (
          <Stack gap={1}>
            <Link href={model.pr.url}>{`Pull request ${prLabel(model.pr)}`}</Link>
            <Plain tone="tertiary">{model.pr.repo}</Plain>
          </Stack>
        ) : model.postUrl ? (
          <Stack gap={1}>
            <Link href={model.postUrl}>Your post</Link>
            <Plain tone="tertiary">{host(model.postUrl)}</Plain>
          </Stack>
        ) : (
          <Plain>{`${ROUTE_LABEL[outlet.route]} · ${host(outlet.link ?? outlet.url)}`}</Plain>
        )}
        <WhenChip model={model} statusAt={statusAt} doneWord={DONE_WORD[outlet.route]} />
        <Row gap={8} align="center">
          {done ? (
            <Button variant="ghost" onClick={() => onPanel("reply")}>
              {panel === "reply" ? "Hide" : hasReply(model.reply) ? "Edit outcome" : "Log outcome"}
            </Button>
          ) : (
            <OutletAction model={model} />
          )}
          <Spacer />
          <Button variant="ghost" onClick={() => onPanel("draft")}>
            {panel === "draft" ? "Hide" : "Text"}
          </Button>
        </Row>
      </div>
      {panel === "draft" ? <DraftPanel model={model} /> : panel === "reply" ? <ReplyEditor model={model} /> : <ReplyLine model={model} />}
    </div>
  );
}

function TodoRow({ item, open, onToggle }: { item: Workstream["needsYou"][number]; open: boolean; onToggle: () => void }) {
  const theme = useHostTheme();
  const [marks, setMarks] = useMarks();
  const done = settled(item, marks);
  const mark = item.done ? undefined : marks[item.id];
  const markLine = item.done
    ? "Done"
    : mark
      ? `${mark.state === "asked" ? "Asked an agent" : mark.state === "done" ? "Done" : "Skipped"} ${day(mark.at)}`
      : "";
  return (
    <div style={{ borderBottom: `1px solid ${theme.stroke.tertiary}` }}>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: ACTION_COLUMNS,
          gap: 10,
          alignItems: "center",
          padding: "7px 0",
          opacity: done ? 0.55 : 1,
        }}
      >
        <Checkbox
          checked={done}
          disabled={item.done}
          onChange={(checked) =>
            setMarks((prev) => {
              const next = { ...prev };
              if (checked) next[item.id] = { state: "done", at: new Date().toISOString() };
              else delete next[item.id];
              return next;
            })
          }
        />
        <Stack gap={1}>
          <Text size="small" weight="medium">
            {item.title}
          </Text>
          <Plain tone="tertiary">{item.blocking ? "To-do · blocks work" : "To-do"}</Plain>
        </Stack>
        <Plain>{`Unblocks: ${item.unblocks}`}</Plain>
        <Plain tone="tertiary">{markLine}</Plain>
        <Row gap={8} align="center">
          <Spacer />
          <Button variant="ghost" onClick={onToggle}>
            {open ? "Hide" : "Details"}
          </Button>
        </Row>
      </div>
      {open ? (
        <div style={{ padding: "2px 0 12px 34px" }}>
          <Stack gap={6}>
            <Plain>{item.detail}</Plain>
            {item.command ? <CommandBlock command={item.command} /> : null}
          </Stack>
        </div>
      ) : null}
    </div>
  );
}

function ActionsTab({ now }: { now: number }) {
  const models = useModels(now).filter((model) => model.outlet.route !== "email");
  const [marks] = useMarks();
  const [show, setShow] = useCanvasState<string>("actionsShow", "all");
  const [open, setOpen] = useState<Record<string, Panel | undefined>>({});
  const todos = workstream.needsYou.filter((item) => !COVERED_BY_CHECKLISTS.has(item.id));
  const keep = (done: boolean, skipped: boolean) => (show === "todo" ? !done && !skipped : show === "done" ? done : true);
  const visibleTodos = todos.filter((item) => keep(settled(item, marks), false));
  const visible = models.filter((model) => keep(isDone(model.status), model.status === "Skipped"));
  const done = models.filter((model) => isDone(model.status)).length;
  const todosDone = todos.filter((item) => settled(item, marks)).length;
  const ids = [...visibleTodos.map((item) => `todo:${item.id}`), ...visible.map((model) => model.outlet.id)];
  const allOpen = ids.length > 0 && ids.every((id) => open[id] === "draft");
  const onPanel = (id: string, panel: Panel) => setOpen((prev) => ({ ...prev, [id]: prev[id] === panel ? undefined : panel }));
  const lastPrCheck = Object.values(PRS)
    .map((pr) => pr.checkedAt ?? "")
    .sort()
    .pop();
  return (
    <Stack gap={12}>
      <Row gap={12} align="center" wrap>
        <Text weight="semibold">{`${done} of ${models.length} actions done`}</Text>
        <Plain tone="tertiary">{`${todosDone} of ${todos.length} to-dos`}</Plain>
        <Spacer />
        <Select
          value={show}
          options={[
            { value: "all", label: "Everything" },
            { value: "todo", label: "To do" },
            { value: "done", label: "Done" },
          ]}
          onChange={setShow}
        />
        <Button variant="ghost" onClick={() => setOpen(allOpen ? {} : Object.fromEntries(ids.map((id): [string, Panel] => [id, "draft"])))}>
          {allOpen ? "Hide text" : "Show all text"}
        </Button>
      </Row>
      <Text size="small" tone="secondary">
        Forms, posts, pull requests and listings, with the text to paste under Text, and your to-dos from Needs you. Tick each one when it&apos;s done.
      </Text>
      {lastPrCheck ? (
        <Row gap={10} align="center" wrap>
          <Plain tone="tertiary">{`Pull requests last checked ${when(lastPrCheck)}. To check again (merged, closed, reviews, comments), run this or ask in chat:`}</Plain>
          <CommandBlock command="~/src/redlamp-outreach/outreach prs" />
        </Row>
      ) : null}
      {(visibleTodos.length > 0 || visible.length > 0) && (
        <div>
          <HeaderCells columns={ACTION_COLUMNS} labels={["Done", "Action", "Where", "When", ""]} />
          {visibleTodos.length > 0 && (
            <div>
              <SectionRow title="Your to-dos" done={todosDone} count={todos.length} noun="done" />
              {visibleTodos.map((item) => (
                <div key={item.id}>
                  <TodoRow item={item} open={open[`todo:${item.id}`] === "draft"} onToggle={() => onPanel(`todo:${item.id}`, "draft")} />
                </div>
              ))}
            </div>
          )}
          {WAVES.map((wave) => {
            const all = models.filter((model) => model.wave === wave.id);
            const rows = visible.filter((model) => model.wave === wave.id);
            if (rows.length === 0) return null;
            return (
              <div key={wave.id}>
                <SectionRow title={wave.label} done={all.filter((model) => isDone(model.status)).length} count={all.length} noun="done" />
                {rows.map((model) => (
                  <div key={model.outlet.id}>
                    <ActionRow model={model} panel={open[model.outlet.id]} onPanel={(panel) => onPanel(model.outlet.id, panel)} />
                  </div>
                ))}
              </div>
            );
          })}
        </div>
      )}
    </Stack>
  );
}

const REPLY_COLUMNS = "minmax(0, 1.2fr) 124px minmax(0, 2.2fr) minmax(0, 1.2fr) 72px";
const WAITING_COLUMNS = "minmax(0, 1.4fr) 150px minmax(0, 1.4fr) 250px";

function waitedFor(iso: string | undefined, now: number): string {
  const time = iso ? Date.parse(iso) : Number.NaN;
  if (Number.isNaN(time)) return "";
  const days = Math.floor((now - time) / DAY);
  return days <= 0 ? "" : days === 1 ? "1 day" : `${days} days`;
}

function nextLine(model: Model, changedAt: string | undefined): string {
  const pitched = model.outlet.route === "email";
  if (model.pr) {
    const review =
      model.pr.review === "CHANGES_REQUESTED" ? "changes requested" : model.pr.review === "APPROVED" ? "approved" : "waiting for review";
    const checks = model.pr.checks ? `, checks ${model.pr.checks}` : "";
    return `Pull request ${review}${checks}`;
  }
  if (model.outlet.route === "post") return "Live: answer comments as they come";
  if (!pitched) return "Waiting for a response";
  if (model.due) return "Follow-up due: one short reply in the same thread";
  if (model.stale) return "A week since the follow-up: mark it No reply";
  if (model.status === "Followed up") return `Followed up ${day(changedAt)}`;
  const sent = model.sentAt ? Date.parse(model.sentAt) : Number.NaN;
  return Number.isNaN(sent) ? "Waiting" : `Follow up from ${day(new Date(sent + 7 * DAY).toISOString())}`;
}

function ReplyRow({ model, open, onToggle }: { model: Model; open: boolean; onToggle: () => void }) {
  const theme = useHostTheme();
  const reply = model.reply ?? NO_REPLY;
  const who = reply.from || model.thread?.replyFrom || "";
  const at = reply.at || model.thread?.replyAt || "";
  return (
    <div style={{ borderBottom: `1px solid ${theme.stroke.tertiary}` }}>
      <div style={{ display: "grid", gridTemplateColumns: REPLY_COLUMNS, gap: 10, alignItems: "start", padding: "8px 0" }}>
        <Stack gap={1}>
          <Link href={model.outlet.url}>{model.outlet.name}</Link>
          <Plain tone="tertiary">{who ? `From ${who}` : model.outlet.group}</Plain>
        </Stack>
        <div>
          <StatusChip status={model.status} label={`${model.status}${at ? ` · ${day(at)}` : ""}`} />
        </div>
        <Clamp text={reply.text || "Add what they said"} tone={reply.text ? "secondary" : "tertiary"} />
        <Stack gap={2}>
          {reply.next ? <Plain>{reply.next}</Plain> : null}
          <CoverageLink link={reply.link} />
        </Stack>
        <Row>
          <Spacer />
          <Button variant="ghost" onClick={onToggle}>
            {open ? "Hide" : "Edit"}
          </Button>
        </Row>
      </div>
      {open ? <ReplyEditor model={model} /> : null}
    </div>
  );
}

function WaitingRow({ model, now, open, onToggle }: { model: Model; now: number; open: boolean; onToggle: () => void }) {
  const theme = useHostTheme();
  const setStatusFor = useSetStatus();
  const [statusAt] = useCanvasState<Record<string, string>>("statusAt", {});
  const outlet = model.outlet;
  const pitched = outlet.route === "email";
  const waited = waitedFor(model.sentAt, now);
  const flagged = model.due || model.stale;
  return (
    <div style={{ borderBottom: `1px solid ${theme.stroke.tertiary}` }}>
      <div style={{ display: "grid", gridTemplateColumns: WAITING_COLUMNS, gap: 10, alignItems: "center", padding: "7px 0" }}>
        <Row gap={8} align="center">
          <StatusDot status={model.status} due={flagged} />
          <Stack gap={1}>
            <Link href={outlet.url}>{outlet.name}</Link>
            <Plain tone="tertiary">{outlet.route === "email" ? (outlet.to ?? []).join(", ") : actionOf(outlet)}</Plain>
          </Stack>
        </Row>
        <Plain>{`Sent ${day(model.sentAt)}${waited ? ` · ${waited}` : ""}`}</Plain>
        <Plain tone={flagged ? "primary" : "tertiary"}>{nextLine(model, statusAt[outlet.id])}</Plain>
        <Row gap={6} align="center">
          <Button variant="ghost" onClick={onToggle}>
            {open ? "Hide" : "Log reply"}
          </Button>
          {pitched && model.status === "Sent" ? (
            <Button variant="ghost" onClick={() => setStatusFor(outlet.id, "Followed up")}>
              Followed up
            </Button>
          ) : null}
          <Button variant="ghost" onClick={() => setStatusFor(outlet.id, "No reply")}>
            No reply
          </Button>
        </Row>
      </div>
      {open ? <ReplyEditor model={model} /> : null}
    </div>
  );
}

function RepliesTab({ now }: { now: number }) {
  const models = useModels(now);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const toggle = (id: string) => setOpen((prev) => ({ ...prev, [id]: !prev[id] }));
  const replyTime = (model: Model) => Date.parse(model.reply?.at || model.thread?.replyAt || "") || 0;
  const sentTime = (model: Model) => Date.parse(model.sentAt ?? "") || 0;
  const answered = models.filter((model) => ANSWERED.includes(model.status)).sort((a, b) => replyTime(b) - replyTime(a));
  const waiting = models
    .filter((model) => model.status === "Sent" || model.status === "Followed up")
    .sort((a, b) => Number(b.due || b.stale) - Number(a.due || a.stale) || sentTime(a) - sentTime(b));
  const quiet = models.filter((model) => model.status === "No reply");
  const covered = answered.filter((model) => model.status === "Covered").length;
  const declined = answered.filter((model) => model.status === "Declined").length;
  const nudges = waiting.filter((model) => model.due || model.stale).length;
  return (
    <Stack gap={20}>
      <Row gap={32} wrap>
        <Stat value={`${answered.length}`} label="Replies" />
        <Stat value={`${covered}`} label="Covered" tone={covered > 0 ? "success" : undefined} />
        <Stat value={`${declined}`} label="Declined" />
        <Stat value={`${waiting.length}`} label="Waiting" />
        <Stat value={`${nudges}`} label="Follow-ups due" tone={nudges > 0 ? "warning" : undefined} />
      </Row>
      <Text size="small" tone="secondary">
        When someone answers, use Log reply on their row: the outcome, the date, who answered, what they said, the next step, and a link if they wrote
        about it. Writing what they said marks it Replied; a coverage link marks it Covered.
      </Text>
      {answered.length > 0 && (
        <Stack gap={6}>
          <H2>Replies</H2>
          <div>
            <HeaderCells columns={REPLY_COLUMNS} labels={["Outlet", "Outcome", "What they said", "Next step", ""]} />
            {answered.map((model) => (
              <div key={model.outlet.id}>
                <ReplyRow model={model} open={open[model.outlet.id] ?? false} onToggle={() => toggle(model.outlet.id)} />
              </div>
            ))}
          </div>
        </Stack>
      )}
      {waiting.length > 0 && (
        <Stack gap={6}>
          <H2>Waiting for a reply</H2>
          <div>
            <HeaderCells columns={WAITING_COLUMNS} labels={["Outlet", "Sent", "Next", ""]} />
            {waiting.map((model) => (
              <div key={model.outlet.id}>
                <WaitingRow model={model} now={now} open={open[model.outlet.id] ?? false} onToggle={() => toggle(model.outlet.id)} />
              </div>
            ))}
          </div>
        </Stack>
      )}
      {quiet.length > 0 && (
        <CollapsibleSection title="No reply" count={quiet.length}>
          <div>
            {quiet.map((model) => (
              <div key={model.outlet.id}>
                <WaitingRow model={model} now={now} open={open[model.outlet.id] ?? false} onToggle={() => toggle(model.outlet.id)} />
              </div>
            ))}
          </div>
        </CollapsibleSection>
      )}
    </Stack>
  );
}

const RULES: { title: string; detail: string }[] = [
  { title: "One person, one email", detail: "Write to the address each outlet publishes for tips or reviews. Never a list, never several outlets in one email." },
  { title: "The first line is theirs", detail: "Each pitch opens with why it fits that outlet. Check the hook is still true before sending." },
  {
    title: "Say who writes the code",
    detail: "One line, with the link to the site's disclosure. Show HN's guidelines, the pixls.us threads and Codeberg's ban show how much people care; better they read it from you.",
  },
  { title: "Plain words", detail: "No 'honest' or 'genuine' (TidBITS asks), no exclamation marks, no superlatives, no em dashes." },
  { title: "Links, not attachments", detail: "The site, the repository and the film are enough; offer files if they ask." },
  { title: "Follow up once", detail: "A week after sending, one short reply in the same thread. Then mark it No reply and move on." },
];

function PitchesTab() {
  const example: Record<string, string> = {
    greeting: "Hello,",
    hook: "[The outlet's own opening line]",
    agentsUrl: "[the write-up's URL]",
    techTitle: "[the technical post's title]",
    techUrl: "[its URL]",
  };
  const uses = (key: string) => DATA.outlets.filter((outlet) => outlet.pitch === key).length;
  return (
    <Stack gap={24}>
      <Grid columns="minmax(0, 1fr) minmax(0, 1fr)" gap={28} align="start">
        <Stack gap={10}>
          <H2>How to pitch</H2>
          {RULES.map((rule) => (
            <div key={rule.title}>
              <Stack gap={1}>
                <Text size="small" weight="semibold">
                  {rule.title}
                </Text>
                <Text size="small" tone="secondary">
                  {rule.detail}
                </Text>
              </Stack>
            </div>
          ))}
        </Stack>
        <Stack gap={10}>
          <H2>Sending from Gmail</H2>
          <Text size="small" tone="secondary">
            Compose in Gmail opens a new message in {DATA.me || "your Gmail account"} with the address, subject and pitch filled in. Nothing is sent until you press
            Send; then set the row to Sent here, and a week later it shows when a follow-up is due.
          </Text>
          <Text size="small" tone="secondary">
            For drafts in bulk and statuses filled in for you, the optional script creates Gmail drafts for the rows you choose and reads those threads
            back. It never sends. It needs the one-time OAuth client in Needs you.
          </Text>
          <CommandBlock command="~/src/redlamp-outreach/outreach drafts --wave now --dry-run" />
          <CommandBlock command="~/src/redlamp-outreach/outreach drafts --wave now" />
          <CommandBlock command="~/src/redlamp-outreach/outreach sync" />
        </Stack>
      </Grid>
      <Divider />
      <Stack gap={10}>
        <H2>Templates</H2>
        <Text size="small" tone="secondary">
          Each email pitch is a template plus the outlet's own opening line, shown here with placeholders. Every row's details show its finished pitch.
        </Text>
        {Object.entries(DATA.templates).map(([key, template]) => (
          <div key={key}>
            <CollapsibleSection title={`${template.use}`} count={uses(key)}>
              <Stack gap={6}>
                <Plain tone="primary">{`Subject: ${fill(template.subject, example)}`}</Plain>
                <CopyBlock text={fill(template.body, example)} />
              </Stack>
            </CollapsibleSection>
          </div>
        ))}
      </Stack>
      <Stack gap={10}>
        <H2>Directory description</H2>
        <Text size="small" tone="secondary">
          For OpenAlternative, Open Source Alternative To, AlternativeTo, MacUpdate and Product Hunt.
        </Text>
        <CopyBlock text={DATA.blurb} />
      </Stack>
      <Stack gap={10}>
        <H2>Checked and left out</H2>
        <Table headers={["Outlet", "Why it isn't in the tracker"]} rows={DATA.leftOut.map((item) => [item.name, item.why])} striped />
      </Stack>
    </Stack>
  );
}

function NextUp({ now }: { now: number }) {
  const theme = useHostTheme();
  const models = useModels(now);
  const due = models.filter((model) => model.due);
  const next = models.filter((model) => model.wave === "now" && (model.status === "To do" || model.status === "Drafted") && model.ready).slice(0, 8);
  if (next.length === 0 && due.length === 0) return null;
  return (
    <Stack gap={10}>
      <H2>Next up</H2>
      {due.length > 0 && (
        <Text size="small">{`Follow-ups due: ${due.map((model) => model.outlet.name).join(", ")}.`}</Text>
      )}
      <div style={{ borderTop: `1px solid ${theme.stroke.tertiary}` }}>
        {next.map((model) => (
          <div
            key={model.outlet.id}
            style={{
              display: "grid",
              gridTemplateColumns: "14px minmax(0, 1.4fr) minmax(0, 1.2fr) 150px",
              gap: 10,
              alignItems: "center",
              padding: "6px 0",
              borderBottom: `1px solid ${theme.stroke.tertiary}`,
            }}
          >
            <StatusDot status={model.status} due={model.due} />
            <Text size="small" weight="medium">
              {model.outlet.name}
            </Text>
            <Plain>{contactLine(model.outlet)}</Plain>
            <OutletAction model={model} />
          </div>
        ))}
      </div>
      <Text size="small" tone="tertiary">
        The highest-priority Wave 1 rows still to do. Set each one's status in Outlets.
      </Text>
    </Stack>
  );
}

function OverviewTab({ now }: { now: number }) {
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
        <NextUp now={now} />
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
          {w.needsYou.length > 0 && <NeedsYou items={w.needsYou} />}
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
  const models = useModels(now);
  const emails = models.filter((model) => model.outlet.route === "email");
  const actions = models.filter((model) => model.outlet.route !== "email");
  const shown: Record<Tab, boolean> = {
    Overview: true,
    Emails: emails.length > 0,
    Actions: actions.length > 0,
    Replies: models.some((model) => isDone(model.status)),
    Outlets: DATA.outlets.length > 0,
    Pitches: Object.keys(DATA.templates).length > 0,
    Plan: w.plan.length > 0,
    Decisions: w.decisions.length > 0,
    Log: w.log.length > 0,
    Measurements: w.measurements.length > 0,
  };
  const tabs = TABS.filter((tab) => shown[tab]);
  const [selected, setSelected] = useCanvasState<Tab>("tab", "Overview");
  const tab: Tab = shown[selected] ? selected : "Overview";
  const [marks] = useMarks();
  const live = w.plan.filter((step) => step.status !== "dropped");
  const done = live.filter((step) => step.status === "done").length;
  const open = w.needsYou.filter((item) => !settled(item, marks));
  const blocking = open.filter((item) => item.blocking).length;
  const emailsSent = emails.filter((model) => isDone(model.status)).length;
  const actionsDone = actions.filter((model) => isDone(model.status)).length;
  const replies = models.filter((model) => ANSWERED.includes(model.status)).length;
  const covered = models.filter((model) => model.status === "Covered").length;
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
        <Stat value={`${emailsSent} of ${emails.length}`} label="Emails sent" tone={emailsSent > 0 ? "success" : undefined} />
        <Stat value={`${actionsDone} of ${actions.length}`} label="Actions done" tone={actionsDone > 0 ? "success" : undefined} />
        <Stat value={`${replies}`} label="Replies" />
        <Stat value={`${covered}`} label="Covered" tone={covered > 0 ? "success" : undefined} />
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
                {name === "Log"
                  ? `Log · ${w.log.length}`
                  : name === "Decisions"
                    ? `Decisions · ${w.decisions.length}`
                    : name === "Outlets"
                      ? `Outlets · ${DATA.outlets.length}`
                      : name === "Emails"
                        ? `Emails · ${emailsSent}/${emails.length}`
                        : name === "Actions"
                          ? `Actions · ${actionsDone}/${actions.length}`
                          : name === "Replies"
                            ? `Replies · ${replies}`
                            : name}
              </Pill>
            </span>
          ))}
        </Row>
      )}
      <Divider />

      {tab === "Overview" && <OverviewTab now={now} />}
      {tab === "Emails" && <EmailsTab now={now} />}
      {tab === "Actions" && <ActionsTab now={now} />}
      {tab === "Replies" && <RepliesTab now={now} />}
      {tab === "Outlets" && <OutletsTab now={now} />}
      {tab === "Pitches" && <PitchesTab />}
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
