import {
  Button,
  Callout,
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

// The supporters room (.cursor/skills/redlamp-supporters/SKILL.md): how Redlamp is funded, from the
// pages people join from to the monthly letter, the quarterly ranking and the report of what came
// in and where it went. Edit only `room` below. An empty list hides its section or tab.

type StepStatus = "done" | "in progress" | "waiting on you" | "not started" | "blocked" | "dropped";
type PostKind = "letter" | "ranking" | "report" | "announcement";
type PostState = "draft" | "scheduled" | "posted" | "skipped";
type RungId = "running" | "research" | "day" | "half" | "full";

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

interface Step {
  id: string;
  step: string;
  detail: string;
  doneWhen: string;
  status: StepStatus;
  /** The commit, tracker row or Needs you item it rests on. */
  ref?: string;
  /** What it waits on, when it can't start yet. */
  note?: string;
}

interface Tier {
  name: string;
  /** Dollars a month. */
  price: number;
  /** Places, when the tier is limited. */
  places?: number;
  /** Who it's for, in a line. */
  pitch: string;
  benefits: string[];
}

interface Copy {
  id: string;
  label: string;
  /** Where it's pasted. */
  where: string;
  text: string;
}

interface Post {
  /** Unique in the room; the owner's marks are kept by it. */
  id: string;
  kind: PostKind;
  title: string;
  /** Everyone, Members, or Insider and Studio. */
  audience: string;
  /** When it's due or went out, as YYYY-MM-DD. */
  due: string;
  state: PostState;
  text: string;
  link?: string;
  note?: string;
}

interface Figures {
  /** Dollars a month: AI subscriptions, hosting, Apple's developer programme, domains. */
  running?: number;
  /** Dollars a month: cameras and lenses, colour targets, film and scanning, training compute. */
  research?: number;
  /** Dollars a month before tax, to work on Redlamp full time. */
  fullTime?: number;
  kofiSupporters?: number;
  /** Dollars: everything Ko-fi has brought in. */
  kofiTotal?: number;
  /** When the agent recorded them from the owner's entries, as YYYY-MM-DD. */
  recorded?: string;
}

interface Period {
  /** "2026-11" or "2026 Q4". */
  period: string;
  members: number;
  /** Dollars after the platforms' fees. */
  patreon: number;
  kofi: number;
  costs: number;
  note?: string;
}

interface Room {
  /** ISO with the time zone. */
  updated: string;
  /** Where support stands, in two or three sentences. */
  summary: string;
  stage: "Preparing" | "Soft launch" | "Live";
  needsYou: NeedsYouItem[];
  plan: Step[];
  /** Shown under the name on Patreon. */
  headline: string;
  /** Patreon's About: the paragraphs before and after the ladder, which is built from the figures. */
  about: { before: string[]; after: string[] };
  /** Cumulative: each step adds to the one before. */
  ladder: { id: RungId; name: string; pays?: string }[];
  tiers: Tier[];
  /** The rest of the Patreon page: the welcome note and the questions. */
  copy: Copy[];
  /** The redlamp.app/support page. */
  supportPage: string;
  figures: Figures;
  /** What the forecast rests on, measured. */
  audience: { label: string; value: string }[];
  audienceSource: string;
  forecast: string;
  /** Letters, rankings, reports and announcements, newest first. */
  posts: Post[];
  /** What came in and went out, in totals only, newest first. */
  money: Period[];
  /** Newest first. */
  log: { at: string; text: string }[];
  decisions: { date: string; decision: string; why: string; by: "Owner" | "Default" }[];
  /** Files in the repository, relative to its root. */
  links: { label: string; path: string }[];
}

const room: Room = {
  updated: "2026-10-08T15:45:00+01:00",
  summary: "Example: where support stands, in two or three sentences, and what the next step waits on.",
  stage: "Preparing",
  needsYou: [
    {
      id: "figures",
      title: "Enter your figures",
      detail:
        "On the Money tab: what Redlamp costs you a month, a monthly research budget, what you'd need to earn a month before tax to work on it full time, and what Ko-fi has brought in so far. They stay in this room's data file on your Mac, and the ladder and the page's draft use them as you type.",
      unblocks: "The amounts on the ladder in the Patreon page's About, and how many members each step takes.",
      blocking: true,
      done: false,
    },
    {
      id: "tiers",
      title: "Approve the tiers",
      detail:
        "Supporter at $5, Insider at $15 and Studio at $50 with ten places, below and on the Pages tab. Press Done to approve them as they are, or Ask the agent with what to change: a price, a name or a perk.",
      unblocks: "Setting the tiers up on Patreon, and the page's final copy.",
      blocking: true,
      done: false,
    },
    {
      id: "copy",
      title: "Approve the page copy",
      detail:
        "Read the Patreon page (headline, About, tiers, welcome note and questions) and redlamp.app/support on the Pages tab. Press Done, or Ask the agent with what to change.",
      unblocks: "Creating the Patreon page, and building redlamp.app/support.",
      blocking: true,
      done: false,
    },
  ],
  plan: [
    {
      id: "room",
      step: "Set up the supporters room",
      detail: "Its skill and template in .cursor/skills/redlamp-supporters, and this room.",
      doneWhen: "The room opens with the drafts, the plan and the figures form.",
      status: "done",
      ref: "Committed on main",
    },
    {
      id: "page",
      step: "Draft the Patreon page and redlamp.app/support",
      detail: "The headline, About with the ladder, three tiers, the welcome note, the questions, and the support page.",
      doneWhen: "You approve the tiers and the copy.",
      status: "waiting on you",
      ref: "Needs you: tiers, copy",
    },
    {
      id: "figures",
      step: "Put amounts on the ladder",
      detail: "Running costs, a research budget and a full-time income give each step its pledges a month and the members it takes.",
      doneWhen: "Every step in About carries an amount.",
      status: "waiting on you",
      ref: "Needs you: figures",
    },
    {
      id: "patreon",
      step: "Create the Patreon page",
      detail:
        "From your personal account: the approved copy and tiers, Studio limited to ten, annual billing on, and Discord connected, with a role per tier and a supporters' channel.",
      doneWhen: "The page is live and its address is in this room.",
      status: "not started",
      note: "Waits on the tiers and the copy.",
    },
    {
      id: "support-page",
      step: "Build redlamp.app/support",
      detail: "The approved copy in web/, linking Patreon, Ko-fi and raw.pixls.us. Another session is working in web/; this waits until it's done.",
      doneWhen: "redlamp.app/support is live.",
      status: "not started",
      note: "Waits on the Patreon page's address.",
    },
    {
      id: "links",
      step: "Point every support link at redlamp.app/support",
      detail:
        "SettingsView.supportURL in the app, the README's badge and closing line, and web/lib/site.ts, plus a .github/FUNDING.yml naming Patreon, Ko-fi and the page. The app's link reaches people with the next release.",
      doneWhen: "No link goes straight to a platform, and the repository shows a Sponsor button.",
      status: "not started",
      note: "Waits on the support page.",
    },
    {
      id: "credits",
      step: "A supporters list in the app and on redlamp.app",
      detail: "Only the names members ask to be credited with, from their reply to the welcome note, with founding supporters marked.",
      doneWhen: "The first member who asked to be credited is listed.",
      status: "not started",
    },
    {
      id: "soft-launch",
      step: "Soft launch",
      detail: "Tell the Discord and the Ko-fi supporters first. Everyone who joins in the first month is a founding supporter.",
      doneWhen: "The announcement is posted and recorded on the Posts tab.",
      status: "not started",
    },
    {
      id: "public-launch",
      step: "Public launch",
      detail: "With a milestone that brings new people, such as AI Denoise or a press wave: a post from the blog room, and the outlets in the press room.",
      doneWhen: "The post is live and the page is announced.",
      status: "not started",
    },
    {
      id: "first-letter",
      step: "The first monthly letter",
      detail: "Drafted from the month's releases, tracker changes, commits and research notes; you edit and post it.",
      doneWhen: "Posted, early in the first month after launch.",
      status: "not started",
    },
    {
      id: "first-ranking",
      step: "The first quarterly ranking",
      detail: "Three to five Accepted rows that haven't started, ranked by Insider and Studio members in a Patreon poll. The winner goes next, and its tracker row says so.",
      doneWhen: "The result is posted and the row is under way.",
      status: "not started",
    },
    {
      id: "first-report",
      step: "The first quarterly report",
      detail: "What came in and where it went, in totals: members, Patreon and Ko-fi after fees, and each cost.",
      doneWhen: "Posted for everyone at the end of the first quarter.",
      status: "not started",
    },
  ],
  headline: "Creating a free, open-source raw photo editor for the Mac",
  about: {
    before: [
      "Hi, I'm Pedro, and I'm building Redlamp: a raw photo editor for the Mac that anyone who knows Lightroom will find familiar. Same panels, same slider names and shortcuts, rebuilt as a native app. iPad and iPhone come after 1.0.",
      "Redlamp is free and open source, and it will stay that way. No subscription, no cloud, and nothing held back for members. Photos are never uploaded.",
      "Making it isn't free, though. Agents write most of Redlamp's code, directed by me and held to the checks in the repository, and that work runs on AI subscriptions. Then there's hosting, Apple's developer programme, cameras and sample files to test against, and a lot of my time. And the goals are ambitious: models trained on photos Redlamp has the rights to, a proper library of camera samples, film scanned and measured. To be honest, that's more than one person can fund alone.",
      "A membership pays for that work, and decides how far it goes. This is the plan, one step at a time:",
    ],
    after: [
      "Every three months I'll publish what came in and where it went.",
      "Members get a letter from me every month, a say in what gets built next, and their name in the app. Higher tiers add a monthly call and, for a few people, time with me looking at how they edit. Everyone who joins in the first month is listed as a founding supporter, for good.",
      "If you'd rather give once, there's Ko-fi. And if your camera isn't verified yet, a sample file helps as much as money: redlamp.app/support says how.",
    ],
  },
  ladder: [
    { id: "running", name: "Running costs", pays: "AI subscriptions, hosting and Apple's developer programme" },
    { id: "research", name: "A research budget", pays: "cameras and lenses to test, colour targets, film and scanning, and compute to train models" },
    { id: "day", name: "A day a week on Redlamp" },
    { id: "half", name: "Half time on Redlamp" },
    { id: "full", name: "Full time on Redlamp" },
  ],
  tiers: [
    {
      name: "Supporter",
      price: 5,
      pitch: "For anyone who wants Redlamp to keep going.",
      benefits: [
        "A letter from me every month: what shipped, what's next and why, and what it cost",
        "Your name in Redlamp's supporters list, in the app and on redlamp.app, if you'd like it there",
        "The supporters' channel on Redlamp's Discord",
      ],
    },
    {
      name: "Insider",
      price: 15,
      pitch: "For people who want a say in what comes next.",
      benefits: [
        "Everything in Supporter",
        "Every three months, rank what gets built next: I pick three to five features I've already accepted for the roadmap, members put them in order, and the top one goes next",
        "A call with me and other members every month, recorded for anyone who can't make it",
      ],
    },
    {
      name: "Studio",
      price: 50,
      places: 10,
      pitch: "For photographers who'd like Redlamp shaped around how they work.",
      benefits: [
        "Everything in Insider",
        "Every three months, 30 minutes with me: edit a few of your own photos in Redlamp while I watch where it gets in your way, or show me what you'd miss from Lightroom",
      ],
    },
  ],
  copy: [
    {
      id: "welcome",
      label: "Welcome note",
      where: "Each tier's welcome note",
      text: [
        "Thanks for joining. It really does help.",
        "One question: how would you like to appear in Redlamp's supporters list? Your name, a handle, or not at all. Just reply to this message.",
        "The letter goes out early each month. Until then, the supporters' channel on Discord is the quickest way to reach me.",
      ].join("\n\n"),
    },
    {
      id: "questions",
      label: "Questions",
      where: "The end of About",
      text: [
        "Will Redlamp stay free?\nYes. Every feature, build and fix is free for everyone, and the code is open source under MPL-2.0. A membership pays for the work. It doesn't buy anything other people can't have.",
        "Do members' bugs get fixed first?\nNo. Bugs are fixed in order of how much they hurt, whoever reports them, from Report a Bug in the app or on GitHub.",
        "Does the ranking mean members decide the roadmap?\nMembers set the order of features I've already said yes to. What goes on the roadmap is still my call, and anyone can suggest something with Send Feedback in the app.",
        "Is Redlamp made with AI?\nAgents write most of the code, directed by me and held to the checks in the repository, and their subscriptions are one of the costs above. Every model Redlamp uses runs on your Mac, and photos are never uploaded. The details are at redlamp.app/#ai.",
        "Can I give once instead?\nYes, on Ko-fi: ko-fi.com/pdcgomes.",
      ].join("\n\n"),
    },
  ],
  supportPage: [
    "Support Redlamp",
    "Redlamp is free and open source, with no subscription and no cloud, and it will stay that way. If you'd like to help it go further, there are a few ways.",
    "Become a member\nOn Patreon, from $5 a month. You get a letter from me every month, a say in what gets built next, and your name in the app.",
    "Give once\nOn Ko-fi, any amount.",
    "Share a sample file\nIf your camera isn't verified yet, share a raw file from it on raw.pixls.us under CC0. Redlamp can then add your camera to the tests that check its decoding and colour on every run.",
    "Test your camera\nHelp › Test Your Camera… compares Redlamp's rendering of your photos with the JPEG your camera saved, on your Mac, and sends only the measurements, which you see first, to the cameras page.",
    "Tell me what's wrong\nHelp › Report a Bug or Send Feedback comes straight to me, and you can follow each report from the app.",
    "Where the money goes\nEvery three months I publish what came in and where it went.",
  ].join("\n\n"),
  figures: {},
  audience: [
    { label: "Stars on GitHub", value: "202" },
    { label: "Unique visitors, 14 days", value: "375" },
    { label: "Downloads of 0.2.6", value: "302" },
    { label: "Downloads of 0.2.4", value: "331" },
  ],
  audienceSource: "GitHub's counts for pdcgomes/redlamp on 8 October 2026. The repository was created on 29 September.",
  forecast:
    "If 1 to 3% of a few hundred regular users joined at about $6 a month, that's 3 to 18 members, or $20 to $110 a month before fees. At list prices, agent work like Redlamp's costs about $100 a month for a roadmap row a week, and $550 for a row every working day (docs/working-with-agents.md). What Ko-fi has brought in is a better guide than these rates.",
  posts: [],
  money: [],
  log: [{ at: "2026-10-08T15:45:00+01:00", text: "Example: what happened, what was found, and what's queued next." }],
  decisions: [
    {
      date: "2026-10-08",
      decision: "Redlamp stays free and open source, for good; support pays for its development and running costs.",
      why: "Your condition from the start.",
      by: "Owner",
    },
    {
      date: "2026-10-08",
      decision: "Nothing is held back for supporters, and bugs are fixed by severity, never by tier.",
      why: "Anything else contradicts free for good, and puts members ahead of the people reporting from the app.",
      by: "Default",
    },
    {
      date: "2026-10-08",
      decision: "Patreon for memberships, Ko-fi for one-off tips, and every link pointing at redlamp.app/support.",
      why: "Photographers know Patreon, and it handles tiers, members' posts, polls and Discord roles. Ko-fi takes one-off tips with no platform fee and is already linked. A page of our own lets the platforms change without a release.",
      by: "Default",
    },
    {
      date: "2026-10-08",
      decision: "Supporters rank what's built next instead of voting on the roadmap.",
      why: "Only you accept rows, and Report a Bug and Send Feedback give everyone the same say. Ranking Accepted rows that haven't started keeps the result binding without handing over the roadmap.",
      by: "Default",
    },
    {
      date: "2026-10-08",
      decision: "Studio's sessions are user research, with ten places.",
      why: "Watching a photographer edit feeds the roadmap. Ten places at one 30-minute session a quarter is 20 hours a year.",
      by: "Default",
    },
    {
      date: "2026-10-08",
      decision: "Supporters' details stay out of the repository: credits only by a member's choice, money only in totals.",
      why: "The repository is public.",
      by: "Default",
    },
  ],
  links: [
    { label: "Skill", path: ".cursor/skills/redlamp-supporters/SKILL.md" },
    { label: "What agent work costs", path: "docs/working-with-agents.md" },
  ],
};

// ---------------------------------------------------------------- rendering (keys sit on wrapper divs)

const TABS = ["Overview", "Pages", "Money", "Posts", "Plan", "Log", "Decisions"] as const;
type Tab = (typeof TABS)[number];
type Tone = "good" | "bad" | "waiting" | "active" | "quiet";

type Mark = { state: "done" | "skipped" | "asked"; at: string };
type Marks = Record<string, Mark>;
type PostMark = { state: "posted" | "scheduled" | "skipped"; at: string };
type PostMarks = Record<string, PostMark>;
type FigureForm = { running: string; research: string; fullTime: string; kofiSupporters: string; kofiTotal: string };

/** What members pay a month on average, for the ladder's counts. */
const AVERAGE_PLEDGE = 8;

const STEP_TONE: Record<StepStatus, Tone> = {
  done: "good",
  "in progress": "active",
  "waiting on you": "waiting",
  "not started": "quiet",
  blocked: "bad",
  dropped: "quiet",
};
const POST_TONE: Record<PostState, Tone> = { posted: "good", scheduled: "active", draft: "waiting", skipped: "quiet" };
const POST_LABEL: Record<PostState, string> = { posted: "Posted", scheduled: "Scheduled", draft: "Ready to post", skipped: "Not posting" };

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

function day(date: string): string {
  const parsed = new Date(`${date}T12:00:00`);
  if (Number.isNaN(parsed.getTime())) return date;
  return parsed.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
}

/** Patreon's cut of one payment: 10% for creators who joined after August 2025, plus card processing (US). */
function fee(price: number): number {
  const processing = price > 3 ? price * 0.029 + 0.3 : price * 0.05 + 0.1;
  return price * 0.1 + processing;
}

function dollars(amount: number): string {
  return `$${Math.round(amount).toLocaleString("en-US")}`;
}

function cents(amount: number): string {
  return `$${amount.toFixed(2)}`;
}

function percent(part: number, whole: number): string {
  return `${((part / whole) * 100).toFixed(1)}%`;
}

function amount(text: string): number | undefined {
  const cleaned = text.replace(/[$,\s]/g, "");
  if (cleaned === "") return undefined;
  const value = Number(cleaned);
  return Number.isFinite(value) && value >= 0 ? value : undefined;
}

function formFrom(figures: Figures): FigureForm {
  const text = (value?: number) => (value === undefined ? "" : `${value}`);
  return {
    running: text(figures.running),
    research: text(figures.research),
    fullTime: text(figures.fullTime),
    kofiSupporters: text(figures.kofiSupporters),
    kofiTotal: text(figures.kofiTotal),
  };
}

function figuresFrom(form: FigureForm): Figures {
  return {
    running: amount(form.running) ?? room.figures.running,
    research: amount(form.research) ?? room.figures.research,
    fullTime: amount(form.fullTime) ?? room.figures.fullTime,
    kofiSupporters: amount(form.kofiSupporters) ?? room.figures.kofiSupporters,
    kofiTotal: amount(form.kofiTotal) ?? room.figures.kofiTotal,
    recorded: room.figures.recorded,
  };
}

interface Rung {
  id: RungId;
  name: string;
  pays?: string;
  /** Dollars a month after fees. */
  net?: number;
  members?: number;
  /** Dollars a month that members pay. */
  pledges?: number;
}

function rungs(figures: Figures): Rung[] {
  const { running, research, fullTime } = figures;
  const base = running !== undefined && research !== undefined ? running + research : undefined;
  const time = (part: number) => (base !== undefined && fullTime !== undefined ? base + fullTime * part : undefined);
  const need: Record<RungId, number | undefined> = { running, research: base, day: time(0.2), half: time(0.5), full: time(1) };
  const perMember = AVERAGE_PLEDGE - fee(AVERAGE_PLEDGE);
  return room.ladder.map((step) => {
    const net = need[step.id];
    if (net === undefined) return { ...step };
    const members = Math.ceil(net / perMember);
    return { ...step, net, members, pledges: members * AVERAGE_PLEDGE };
  });
}

function aboutText(ladder: Rung[]): string {
  const steps = ladder
    .map((step, index) => `${index + 1}. ${step.name}${step.pledges !== undefined ? ` (${dollars(step.pledges)} a month)` : ""}${step.pays ? `: ${step.pays}` : ""}.`)
    .join("\n");
  return [...room.about.before, steps, ...room.about.after].join("\n\n");
}

function tierText(tier: Tier): string {
  return `${tier.pitch}\n\n${tier.benefits.map((benefit) => `- ${benefit}`).join("\n")}`;
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

function Eyebrow({ children }: { children: string }) {
  const theme = useHostTheme();
  return (
    <span style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.08em", textTransform: "uppercase", color: theme.text.tertiary }}>
      {children}
    </span>
  );
}

function CopyText({ text }: { text: string }) {
  const theme = useHostTheme();
  const [said, setSaid] = useState<string | null>(null);
  const copy = () => {
    const clipboard = typeof navigator === "undefined" ? undefined : navigator.clipboard;
    if (!clipboard) {
      setSaid("Click the text to select it, then press ⌘C");
      return;
    }
    clipboard.writeText(text).then(
      () => setSaid("Copied"),
      () => setSaid("Click the text to select it, then press ⌘C"),
    );
  };
  return (
    <Stack gap={6}>
      <div
        style={{
          whiteSpace: "pre-wrap",
          fontSize: 13,
          lineHeight: "19px",
          padding: "10px 12px",
          borderRadius: 6,
          background: theme.fill.tertiary,
          color: theme.text.primary,
          wordBreak: "break-word",
          userSelect: "all",
        }}
      >
        {text}
      </div>
      <Row gap={8} align="center">
        <Button variant="secondary" onClick={copy}>
          Copy
        </Button>
        {said ? (
          <Text size="small" tone="tertiary">
            {said}
          </Text>
        ) : null}
      </Row>
    </Stack>
  );
}

function Block({ label, where, text }: { label: string; where: string; text: string }) {
  return (
    <Stack gap={6}>
      <Row gap={8} align="center">
        <Text size="small" weight="semibold">
          {label}
        </Text>
        <Spacer />
        <Text size="small" tone="tertiary">
          {where}
        </Text>
      </Row>
      <CopyText text={text} />
    </Stack>
  );
}

function settled(item: NeedsYouItem, marks: Marks): boolean {
  if (item.done) return true;
  const state = marks[item.id]?.state;
  return state === "done" || state === "skipped";
}

function NeedsYouRow({ item, marks, setMarks }: { item: NeedsYouItem; marks: Marks; setMarks: SetCanvasState<Marks> }) {
  const dispatch = useCanvasAction();
  const closed = settled(item, marks);
  const mark = marks[item.id];
  const set = (state: Mark["state"] | null) =>
    setMarks((previous) => {
      const next = { ...previous };
      if (state) next[item.id] = { state, at: new Date().toISOString() };
      else delete next[item.id];
      return next;
    });
  const ask = () => {
    set("asked");
    dispatch({
      type: "newComposerChat",
      userPrompt:
        `From the supporters room's Needs you list, please take on "${item.title}" (item ${item.id}): ${item.detail}` +
        `${item.command ? ` The command: ${item.command}` : ""} ` +
        "Follow .cursor/skills/redlamp-supporters/SKILL.md, and update the supporters room with what came of it.",
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
          {item.blocking && !closed ? <Pill size="sm">Blocks the launch</Pill> : null}
          {mark?.state === "asked" && !closed ? <Pill size="sm">With an agent</Pill> : null}
        </Row>
        <Text size="small" tone="secondary">
          {item.detail}
        </Text>
        <Text size="small" tone="tertiary">
          {`Unblocks: ${item.unblocks}`}
        </Text>
        {!item.done && mark && mark.state !== "asked" ? (
          <Row gap={8} align="center">
            <Text size="small" tone="tertiary">
              {`${mark.state === "done" ? "Marked done by you" : "Skipped"}, ${when(mark.at)}; the agent picks it up at its next update.`}
            </Text>
            <Button variant="ghost" onClick={() => set(null)}>
              Undo
            </Button>
          </Row>
        ) : null}
        {!closed ? (
          <Row gap={6} style={{ paddingTop: 4 }}>
            <Button variant="secondary" onClick={() => set("done")}>
              Done
            </Button>
            <Button variant="ghost" onClick={() => set("skipped")}>
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

function NeedsYou({ marks, setMarks }: { marks: Marks; setMarks: SetCanvasState<Marks> }) {
  const open = room.needsYou.filter((item) => !settled(item, marks)).sort((a, b) => Number(b.blocking) - Number(a.blocking));
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
          <NeedsYouRow item={item} marks={marks} setMarks={setMarks} />
        </div>
      ))}
      {done.length > 0 && (
        <CollapsibleSection title="Done" count={done.length} defaultOpen={open.length === 0}>
          <Stack gap={10}>
            {done.map((item) => (
              <div key={item.id}>
                <NeedsYouRow item={item} marks={marks} setMarks={setMarks} />
              </div>
            ))}
          </Stack>
        </CollapsibleSection>
      )}
    </Stack>
  );
}

function TiersAtAGlance() {
  const theme = useHostTheme();
  return (
    <Stack gap={10}>
      <H3>The tiers</H3>
      <Grid columns={room.tiers.length} gap={0} align="stretch">
        {room.tiers.map((tier, index) => (
          <div
            key={tier.name}
            style={{ padding: "4px 14px 4px 0", paddingLeft: index === 0 ? 0 : 14, borderLeft: index === 0 ? undefined : `1px solid ${theme.stroke.tertiary}` }}
          >
            <Stack gap={6}>
              <Row gap={8} align="center">
                <Text weight="semibold">{tier.name}</Text>
                <Spacer />
                <Text size="small" tone="secondary">
                  {`$${tier.price} a month`}
                </Text>
              </Row>
              {tier.places ? (
                <Text size="small" tone="tertiary">
                  {`${tier.places} places`}
                </Text>
              ) : null}
              <Text size="small" tone="secondary">
                {tier.pitch}
              </Text>
              {tier.benefits.map((benefit) => (
                <div key={benefit}>
                  <Text size="small">{benefit}</Text>
                </div>
              ))}
            </Stack>
          </div>
        ))}
      </Grid>
    </Stack>
  );
}

function PlanCompact() {
  const done = room.plan.filter((step) => step.status === "done").length;
  return (
    <Stack gap={10}>
      <Row gap={8} align="center">
        <H3>The launch</H3>
        <Spacer />
        <Text size="small" tone="tertiary">
          {`${done} of ${room.plan.length} done`}
        </Text>
      </Row>
      <Stack gap={7}>
        {room.plan.map((step) => (
          <div key={step.id} style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) auto", gap: 10, alignItems: "center" }}>
            <Text size="small" tone={step.status === "done" || step.status === "dropped" ? "tertiary" : "primary"}>
              {step.step}
            </Text>
            <Status tone={STEP_TONE[step.status]} label={step.status} />
          </div>
        ))}
      </Stack>
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

function OverviewTab({ now, marks, setMarks }: { now: number; marks: Marks; setMarks: SetCanvasState<Marks> }) {
  return (
    <Grid columns="minmax(0, 1.45fr) minmax(0, 1fr)" gap={32} align="start">
      <Stack gap={28}>
        {room.needsYou.length > 0 && <NeedsYou marks={marks} setMarks={setMarks} />}
        {room.tiers.length > 0 && <TiersAtAGlance />}
      </Stack>
      <Stack gap={20}>
        {room.plan.length > 0 && <PlanCompact />}
        {room.log.length > 0 && (
          <>
            <Divider />
            <Stack gap={10}>
              <H3>Latest</H3>
              <LogEntries entries={room.log.slice(0, 2)} now={now} />
            </Stack>
          </>
        )}
      </Stack>
    </Grid>
  );
}

function PagesTab({ ladder }: { ladder: Rung[] }) {
  const priced = ladder.some((step) => step.pledges !== undefined);
  return (
    <Stack gap={28}>
      <Stack gap={16}>
        <Stack gap={4}>
          <Eyebrow>Patreon</Eyebrow>
          <H2>The Patreon page</H2>
          <Text size="small" tone="secondary">
            Each block goes into the Patreon field named beside it. The ladder in About takes its amounts from the figures on the Money tab.
          </Text>
        </Stack>
        {!priced ? <Callout tone="info">The ladder has no amounts yet. Enter your figures on the Money tab, and they appear in About.</Callout> : null}
        <Block label="Headline" where="Under the page's name" text={room.headline} />
        <Block label="About" where="About" text={aboutText(ladder)} />
        <Stack gap={10}>
          <H3>Tiers</H3>
          <Grid columns={room.tiers.length} gap={16} align="start">
            {room.tiers.map((tier) => (
              <div key={tier.name}>
                <Stack gap={8}>
                  <Row gap={8} align="center">
                    <Text weight="semibold">{tier.name}</Text>
                    <Spacer />
                    <Text size="small" tone="secondary">
                      {`$${tier.price} a month${tier.places ? `, ${tier.places} places` : ""}`}
                    </Text>
                  </Row>
                  <CopyText text={tierText(tier)} />
                </Stack>
              </div>
            ))}
          </Grid>
          <Text size="small" tone="tertiary">
            Paste each into its tier's description. In the tiers' settings, turn on annual billing and limit Studio to its places.
          </Text>
        </Stack>
        {room.copy.map((item) => (
          <div key={item.id}>
            <Block label={item.label} where={item.where} text={item.text} />
          </div>
        ))}
      </Stack>
      <Divider />
      <Stack gap={12}>
        <Stack gap={4}>
          <Eyebrow>redlamp.app</Eyebrow>
          <H2>redlamp.app/support</H2>
          <Text size="small" tone="secondary">
            The page every support link points at: the app's Settings, the README and the site. It's built in web/ once the Patreon page has its address.
          </Text>
        </Stack>
        <CopyText text={room.supportPage} />
      </Stack>
    </Stack>
  );
}

function Field({ label, hint, value, onChange }: { label: string; hint: string; value: string; onChange: (value: string) => void }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) 120px", gap: 12, alignItems: "center" }}>
      <Stack gap={0}>
        <Text size="small" weight="medium">
          {label}
        </Text>
        <Text size="small" tone="tertiary">
          {hint}
        </Text>
      </Stack>
      <TextInput value={value} onChange={onChange} placeholder="0" />
    </div>
  );
}

function MoneyTab({ form, setForm, figures, ladder }: { form: FigureForm; setForm: SetCanvasState<FigureForm>; figures: Figures; ladder: Rung[] }) {
  const priced = ladder.some((step) => step.pledges !== undefined);
  const set = (key: keyof FigureForm) => (value: string) => setForm((previous) => ({ ...previous, [key]: value }));
  const kofi = [
    figures.kofiSupporters !== undefined ? `${figures.kofiSupporters} supporters` : undefined,
    figures.kofiTotal !== undefined ? dollars(figures.kofiTotal) : undefined,
  ].filter(Boolean);
  return (
    <Grid columns="minmax(0, 1.4fr) minmax(0, 1fr)" gap={32} align="start">
      <Stack gap={26}>
        <Stack gap={10}>
          <H3>The funding ladder</H3>
          <Text size="small" tone="secondary">
            {`Each step adds to the one before. With your figures in, each shows what members would pay a month to cover it after Patreon's fees, and how many members that takes at an average of $${AVERAGE_PLEDGE}.`}
          </Text>
          {priced ? (
            <Table
              headers={["Step", "Pays for", "Pledges a month", `Members at $${AVERAGE_PLEDGE}`]}
              columnAlign={[undefined, undefined, "right", "right"]}
              rows={ladder.map((step, index) => [
                `${index + 1}. ${step.name}`,
                step.pays ?? "Your time",
                step.pledges !== undefined ? dollars(step.pledges) : <Text size="small" tone="tertiary">Needs a figure</Text>,
                step.members !== undefined ? step.members.toLocaleString("en-US") : "",
              ])}
            />
          ) : (
            <Stack gap={6}>
              {ladder.map((step, index) => (
                <div key={step.id}>
                  <Text size="small">{`${index + 1}. ${step.name}${step.pays ? `: ${step.pays}` : ""}`}</Text>
                </div>
              ))}
            </Stack>
          )}
          <Text size="small" tone="tertiary">
            Running costs and the research budget are monthly; a day a week, half time and full time add a fifth, a half and all of the full-time income. Source: your figures in this room.
          </Text>
        </Stack>
        <Stack gap={10}>
          <H3>Patreon's fees on each tier</H3>
          <Table
            headers={["Tier", "Price", "Fees on a monthly payment", "Fees on an annual payment"]}
            columnAlign={[undefined, "right", "right", "right"]}
            rows={room.tiers.map((tier) => {
              const monthly = fee(tier.price);
              const annual = fee(tier.price * 12);
              return [
                tier.name,
                `$${tier.price} a month`,
                `${cents(monthly)} (${percent(monthly, tier.price)})`,
                `${cents(annual)} a year (${percent(annual, tier.price * 12)})`,
              ];
            })}
          />
          <Text size="small" tone="tertiary">
            Patreon's rates as last known: 10% for creators who joined after August 2025, plus card processing of 2.9% and $0.30 a payment over $3, or 5% and $0.10 at $3 or less (US cards). Check Patreon's pricing page before setting prices.
          </Text>
        </Stack>
        {room.money.length > 0 && (
          <Stack gap={10}>
            <H3>What came in and where it went</H3>
            <Table
              headers={["Period", "Members", "Patreon after fees", "Ko-fi", "Costs", "Left over"]}
              columnAlign={[undefined, "right", "right", "right", "right", "right"]}
              rows={room.money.map((period) => [
                period.period,
                `${period.members}`,
                dollars(period.patreon),
                dollars(period.kofi),
                dollars(period.costs),
                dollars(period.patreon + period.kofi - period.costs),
              ])}
            />
            <Text size="small" tone="tertiary">
              In dollars, totals only, from the platforms' exports and your costs.
            </Text>
          </Stack>
        )}
      </Stack>
      <Stack gap={24}>
        <Stack gap={12}>
          <H3>Your figures</H3>
          <Text size="small" tone="secondary">
            In dollars. They stay in this room's data file on your Mac, and the ladder and the Patreon page's draft use them as you type.
          </Text>
          <Field label="Running costs a month" hint="AI subscriptions, hosting, Apple's developer programme, domains" value={form.running} onChange={set("running")} />
          <Field label="Research budget a month" hint="Cameras and lenses, colour targets, film and scanning, training compute" value={form.research} onChange={set("research")} />
          <Field label="Full-time income a month" hint="What you'd need to earn before tax to work on Redlamp full time" value={form.fullTime} onChange={set("fullTime")} />
          <Field label="Ko-fi supporters so far" hint="People, not payments" value={form.kofiSupporters} onChange={set("kofiSupporters")} />
          <Field label="Ko-fi total so far" hint="Everything it has brought in" value={form.kofiTotal} onChange={set("kofiTotal")} />
          {figures.recorded ? (
            <Text size="small" tone="tertiary">
              {`Recorded in the room on ${day(figures.recorded)}.`}
            </Text>
          ) : null}
        </Stack>
        <Divider />
        <Stack gap={12}>
          <H3>What to expect now</H3>
          <Grid columns={2} gap={14}>
            {room.audience.map((item) => (
              <div key={item.label}>
                <Stat value={item.value} label={item.label} />
              </div>
            ))}
          </Grid>
          <Text size="small">{room.forecast}</Text>
          {kofi.length > 0 ? (
            <Text size="small" tone="secondary">
              {`Ko-fi so far: ${kofi.join(", ")}.`}
            </Text>
          ) : null}
          <Text size="small" tone="tertiary">
            {room.audienceSource}
          </Text>
        </Stack>
      </Stack>
    </Grid>
  );
}

/** The owner's mark on a post while the room hasn't recorded it: one made after the room's last update. */
function pendingMark(post: Post, marks: PostMarks): PostMark | undefined {
  const mark = marks[post.id];
  return mark && Date.parse(mark.at) > Date.parse(room.updated) ? mark : undefined;
}

function postState(post: Post, marks: PostMarks): PostState {
  return pendingMark(post, marks)?.state ?? post.state;
}

function PostButtons({ post, marks, setMarks }: { post: Post; marks: PostMarks; setMarks: SetCanvasState<PostMarks> }) {
  const mark = pendingMark(post, marks);
  const set = (state: PostMark["state"] | null) =>
    setMarks((previous) => {
      const next = { ...previous };
      if (state) next[post.id] = { state, at: new Date().toISOString() };
      else delete next[post.id];
      return next;
    });
  if (mark) {
    const said = { posted: "Marked posted", scheduled: "Marked scheduled", skipped: "Skipped" }[mark.state];
    return (
      <Row gap={8} align="center">
        <Text size="small" tone="tertiary">
          {`${said} by you, ${when(mark.at)}; the agent records it at its next update.`}
        </Text>
        <Button variant="ghost" onClick={() => set(null)}>
          Undo
        </Button>
      </Row>
    );
  }
  if (post.state === "posted" || post.state === "skipped") return null;
  return (
    <Row gap={6}>
      <Button variant="secondary" onClick={() => set("posted")}>
        Posted
      </Button>
      {post.state === "draft" ? (
        <Button variant="ghost" onClick={() => set("scheduled")}>
          Scheduled
        </Button>
      ) : null}
      <Button variant="ghost" onClick={() => set("skipped")}>
        Skip
      </Button>
    </Row>
  );
}

function PostsTab({ marks, setMarks }: { marks: PostMarks; setMarks: SetCanvasState<PostMarks> }) {
  return (
    <Stack gap={18}>
      {room.posts.map((post, index) => {
        const state = postState(post, marks);
        return (
          <div key={post.id}>
            <Stack gap={10}>
              {index > 0 ? <Divider /> : null}
              <Row gap={10} align="center">
                <Text weight="semibold">{post.title}</Text>
                <Pill size="sm">{post.kind}</Pill>
                <Spacer />
                <Status tone={POST_TONE[state]} label={POST_LABEL[state]} />
              </Row>
              <Text size="small" tone="tertiary">
                {`${post.audience} · ${day(post.due)}`}
              </Text>
              {post.note ? (
                <Text size="small" tone="secondary">
                  {post.note}
                </Text>
              ) : null}
              {post.link ? <Link href={post.link}>{post.link}</Link> : null}
              {state === "posted" ? (
                <CollapsibleSection title="The text">
                  <CopyText text={post.text} />
                </CollapsibleSection>
              ) : (
                <CopyText text={post.text} />
              )}
              <PostButtons post={post} marks={marks} setMarks={setMarks} />
            </Stack>
          </div>
        );
      })}
    </Stack>
  );
}

function PlanTab() {
  return (
    <Table
      headers={["Step", "What it involves", "Done when", "Status"]}
      rows={room.plan.map((step) => [
        <Text size="small" weight="medium">
          {step.step}
        </Text>,
        <Stack gap={2}>
          <Text size="small">{step.detail}</Text>
          {step.note ? (
            <Text size="small" tone="tertiary">
              {step.note}
            </Text>
          ) : null}
        </Stack>,
        <Text size="small" tone="secondary">
          {step.doneWhen}
        </Text>,
        <Stack gap={2}>
          <span style={{ whiteSpace: "nowrap" }}>
            <Status tone={STEP_TONE[step.status]} label={step.status} />
          </span>
          {step.ref ? (
            <Text size="small" tone="tertiary">
              {step.ref}
            </Text>
          ) : null}
        </Stack>,
      ])}
    />
  );
}

function Links() {
  const dispatch = useCanvasAction();
  return (
    <Row gap={6} align="center" wrap>
      {room.links.map((link) => (
        <span key={link.path}>
          <Button variant="ghost" onClick={() => dispatch({ type: "openFile", path: link.path })}>
            {link.label}
          </Button>
        </span>
      ))}
    </Row>
  );
}

export default function SupportersRoom() {
  const now = useNow();
  const [marks, setMarks] = useCanvasState<Marks>("needsYou", {});
  const [postMarks, setPostMarks] = useCanvasState<PostMarks>("posts", {});
  const [form, setForm] = useCanvasState<FigureForm>("figures", formFrom(room.figures));
  const [selected, setSelected] = useCanvasState<Tab>("tab", "Overview");
  const figures = figuresFrom(form);
  const ladder = rungs(figures);
  const shown: Record<Tab, boolean> = {
    Overview: true,
    Pages: room.tiers.length > 0,
    Money: true,
    Posts: room.posts.length > 0,
    Plan: room.plan.length > 0,
    Log: room.log.length > 0,
    Decisions: room.decisions.length > 0,
  };
  const tabs = TABS.filter((tab) => shown[tab]);
  const tab: Tab = shown[selected] ? selected : "Overview";
  const open = room.needsYou.filter((item) => !settled(item, marks)).length;
  const done = room.plan.filter((step) => step.status === "done").length;
  const latest = room.money[0];
  const toPost = room.posts.filter((post) => postState(post, postMarks) === "draft").length;
  return (
    <Stack gap={18} style={{ padding: 4 }}>
      <Stack gap={6}>
        <H1>Supporters room</H1>
        <Text>{room.summary}</Text>
        <Text size="small" tone="tertiary">
          {`Updated ${ago(room.updated, now)} (${when(room.updated)})`}
        </Text>
      </Stack>

      <Row gap={32} wrap>
        <Stat value={room.stage} label="Stage" />
        <Stat value={`${open}`} label="Waiting on you" tone={open > 0 ? "warning" : undefined} />
        <Stat value={`${done} of ${room.plan.length}`} label="Launch steps done" />
        {latest ? <Stat value={`${latest.members}`} label={`Members, ${latest.period}`} /> : null}
        {toPost > 0 ? <Stat value={`${toPost}`} label="Ready to post" /> : null}
      </Row>

      <Row gap={6} wrap>
        {tabs.map((name) => (
          <span key={name}>
            <Pill active={tab === name} onClick={() => setSelected(name)}>
              {name === "Log" ? `Log · ${room.log.length}` : name}
            </Pill>
          </span>
        ))}
      </Row>
      <Divider />

      {tab === "Overview" && <OverviewTab now={now} marks={marks} setMarks={setMarks} />}
      {tab === "Pages" && <PagesTab ladder={ladder} />}
      {tab === "Money" && <MoneyTab form={form} setForm={setForm} figures={figures} ladder={ladder} />}
      {tab === "Posts" && <PostsTab marks={postMarks} setMarks={setPostMarks} />}
      {tab === "Plan" && <PlanTab />}
      {tab === "Log" && <LogEntries entries={room.log} now={now} />}
      {tab === "Decisions" && (
        <Table headers={["Date", "Decision", "Why", "By"]} rows={room.decisions.map((d) => [d.date, d.decision, d.why, d.by])} striped />
      )}
      {room.links.length > 0 && <Links />}
    </Stack>
  );
}
