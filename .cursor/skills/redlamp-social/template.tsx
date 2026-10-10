import {
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
import type { SetCanvasState, StackProps } from "cursor/canvas";

// The social room (.cursor/skills/redlamp-social/SKILL.md): Redlamp's Instagram and TikTok posts, from
// storyboard to posted. Edit only `room` below. room.py room writes POSTS from docs/social/posts.json, and
// room.py thumbs writes THUMBS from the storyboards. An empty list hides its section or tab.

type StepStatus = "not started" | "in progress" | "done" | "blocked" | "dropped";
type Platform = "instagram" | "tiktok";
/** An episode's production stage, as posts.json records it. */
type Stage = "storyboard" | "building" | "in review" | "approved" | "rendered";

interface NeedsYouItem {
  id: string;
  title: string;
  /** Exactly what to do and where; once done, "Done: …" with what came of it. */
  detail: string;
  /** True when work waits on it. */
  blocking?: boolean;
  /** A shell line to copy. */
  command?: string;
  unblocks?: string;
  /** Keep an item once it's done, with `detail` starting "Done:". */
  done?: boolean;
}

interface Room {
  /** Where the campaign stands, in two or three sentences. */
  summary: string;
  /** A word or two beside the title: "Planning", "Posting", "Paused". */
  status: string;
  /** When the room was last brought up to date: ISO with the offset. */
  updated: string;
  needsYou: NeedsYouItem[];
  /** In order; with a plan, one step per todo, with the todo's ID. */
  plan: { id: string; step: string; detail: string; doneWhen: string; status: StepStatus; note?: string }[];
  /** Newest first; `at` is ISO with the offset. */
  log: { at: string; text: string }[];
  /** Appended as they happen; a reversed decision is a new row. */
  decisions: { date: string; decision: string; why: string; by: "Owner" | "Measured" | "Default" }[];
  /** Each account once it exists, and how the room reaches it. */
  platforms: Record<Platform, { account?: string; connection: string }>;
}

/** docs/social/posts.json; room.py checks it before writing it into POSTS. */
interface Episode {
  id: string;
  title: string;
  feature: string;
  audience: string;
  /** Where each claim comes from: the README or docs/lightroom-comparison.md. */
  source: string;
  stage: Stage;
  /** Each hook's lines on screen: at most two, of at most 17 characters. */
  hooks: Record<"a" | "b", string[]>;
  endLine: string[];
  result: string;
}

interface Post {
  id: string;
  episode: string;
  hook: "a" | "b";
  /** ISO with the offset. */
  at: string;
  platforms: Platform[];
  /** An Instagram trial reel, shown only to non-followers; MANUAL leaves sharing it with followers to the owner. */
  trial?: "MANUAL" | "SS_PERFORMANCE";
  /** The render's name in ~/src/redlamp-social/renders/ */
  file: string;
  /** The cover's frame, in milliseconds from the start. */
  coverMs: number;
  caption: string;
  alt: string;
  /** Something to check before rendering or posting. */
  check?: string;
}

interface Schedule {
  timeZone: string;
  campaign: { id: string; title: string; doc: string };
  /** The lines every caption carries, and the end card every video ends on. */
  standard: { about: string; cta: string; requirements: string; endCard: string[] };
  episodes: Episode[];
  posts: Post[];
}

const room: Room = {
  summary: "Example: ten feature videos are planned for Instagram and TikTok from Tue 27 Oct. Nothing has been posted yet.",
  status: "Planning",
  updated: "2026-10-10T08:00:00+01:00",
  needsYou: [
    {
      id: "example",
      title: "Example: create the accounts",
      detail: "Example: exactly what to do, and where.",
      unblocks: "Example: what it unblocks.",
    },
  ],
  plan: [
    {
      id: "example",
      step: "Example step",
      detail: "Example: what the step involves.",
      doneWhen: "Example: when it counts as done.",
      status: "in progress",
    },
  ],
  log: [{ at: "2026-10-10T08:00:00+01:00", text: "Example." }],
  decisions: [{ date: "2026-10-10", decision: "Example: a decision", why: "Example: why it was made.", by: "Owner" }],
  platforms: {
    instagram: { connection: "Example: no account yet" },
    tiktok: { connection: "Example: no account yet" },
  },
};

// POSTS:BEGIN (room.py room writes this block from docs/social/posts.json)
const POSTS: Schedule = {
  "timeZone": "Europe/London",
  "campaign": {
    "id": "features",
    "title": "Feature videos",
    "doc": "docs/plans/2026-10-10-feature-videos.md"
  },
  "standard": {
    "about": "Redlamp is a free raw photo editor for Mac, with Lightroom's layout and shortcuts.",
    "cta": "Download it at redlamp.app (link in bio).",
    "requirements": "Needs an Apple Silicon Mac with macOS 26. It's in early development.",
    "endCard": [
      "DOWNLOAD FREE",
      "REDLAMP.APP"
    ]
  },
  "episodes": [
    {
      "id": "e01",
      "title": "Free",
      "feature": "A free, open-source raw photo editor for Mac, with no subscription and no cloud.",
      "audience": "Everyone, and people paying a monthly subscription for photo editing.",
      "source": "README: Support Redlamp (free, no subscription, no cloud); Goals 8 (open source).",
      "stage": "storyboard",
      "hooks": {
        "a": [
          "A FREE RAW PHOTO",
          "EDITOR FOR MAC"
        ],
        "b": [
          "NO SUBSCRIPTION.",
          "NO CLOUD."
        ]
      },
      "endLine": [
        "RAW PHOTO EDITOR",
        "FOR MAC"
      ],
      "result": "A real photo before and after, edited in Redlamp."
    }
  ],
  "posts": [
    {
      "id": "e01",
      "episode": "e01",
      "hook": "a",
      "at": "2026-10-27T18:00:00+00:00",
      "platforms": [
        "instagram",
        "tiktok"
      ],
      "file": "e01-a.mp4",
      "coverMs": 0,
      "caption": "A free raw photo editor for Mac, with no subscription and no cloud. Redlamp is open source, and it has Lightroom's layout and shortcuts. Download it at redlamp.app (link in bio). Needs an Apple Silicon Mac with macOS 26. It's in early development.\n\n#photoediting #rawphoto #lightroom #macos #photography",
      "alt": "Pixel art of a photo editor on a Mac. A raw photo opens, and the words No subscription, No cloud and Open source appear one after another as sliders adjust it. Then the real photo, edited in Redlamp, appears before and after. The video ends with Download free, redlamp.app."
    },
    {
      "id": "e01-trial",
      "episode": "e01",
      "hook": "b",
      "at": "2026-10-29T18:00:00+00:00",
      "platforms": [
        "instagram"
      ],
      "trial": "MANUAL",
      "file": "e01-b.mp4",
      "coverMs": 0,
      "caption": "A free raw photo editor for Mac, with no subscription and no cloud. Redlamp is open source, and it has Lightroom's layout and shortcuts. Download it at redlamp.app (link in bio). Needs an Apple Silicon Mac with macOS 26. It's in early development.\n\n#photoediting #rawphoto #lightroom #macos #photography",
      "alt": "Pixel art of a photo editor on a Mac. A raw photo opens, and the words No subscription, No cloud and Open source appear one after another as sliders adjust it. Then the real photo, edited in Redlamp, appears before and after. The video ends with Download free, redlamp.app."
    }
  ]
};
// POSTS:END

// THUMBS:BEGIN (room.py thumbs writes this block from video/out/features/boards/)
const THUMBS: Record<string, string> = {
};
// THUMBS:END

// PUBLISHED: what's on Instagram, by post ID, from ~/src/redlamp-social/state/published.json, the
// publisher's record: when each post went out, who posted it (the owner by hand, recorded with
// room.py published, or the publisher once it's built) and its link when known. A post in it shows as
// posted, and the publisher never posts it again.
type Published = { at: string; by: "hand" | "publisher"; link?: string; mediaId?: string };

// PUBLISHED:BEGIN (room.py writes this block from ~/src/redlamp-social/state/published.json)
const PUBLISHED: Record<string, Published> = {};
// PUBLISHED:END

// ---------------------------------------------------------------- rendering (keys sit on wrapper divs)

const TABS = ["Now", "Schedule", "Posts", "Platforms", "Plan", "Log", "Decisions"] as const;
type Tab = (typeof TABS)[number];
type Tone = "good" | "waiting" | "active" | "quiet";

/**
 * The owner's marks, kept in the room's .canvas.data.json, which agents read but never write: needsYou;
 * cut:<episode> and post:<post id>, where a post's approval keeps the caption it approved; tiktok:<post id>;
 * and link:<post id>:tiktok. Undo sets a mark to null.
 */
type Mark = { state: "done" | "skipped" | "asked"; at: string };
type Marks = Record<string, Mark>;
type Approval = { state: "approved" | "held"; at: string; caption?: string };
type TikTokMark = { state: "scheduled" | "posted" | "skipped"; at: string };
type PlatformState = "planned" | TikTokMark["state"];

const NAME: Record<Platform, string> = { instagram: "Instagram", tiktok: "TikTok" };
const STAGE: Record<Stage, { label: string; tone: Tone }> = {
  storyboard: { label: "Storyboard", tone: "quiet" },
  building: { label: "Building", tone: "active" },
  "in review": { label: "In review", tone: "waiting" },
  approved: { label: "Cut approved", tone: "good" },
  rendered: { label: "Rendered", tone: "good" },
};
const PLATFORM_STATE: Record<PlatformState, { label: string; tone: Tone }> = {
  planned: { label: "Planned", tone: "quiet" },
  scheduled: { label: "Scheduled", tone: "active" },
  posted: { label: "Posted", tone: "good" },
  skipped: { label: "Skipped", tone: "quiet" },
};
const STEP: Record<StepStatus, { label: string; tone: Tone }> = {
  done: { label: "Done", tone: "good" },
  "in progress": { label: "In progress", tone: "active" },
  "not started": { label: "Not started", tone: "quiet" },
  blocked: { label: "Blocked", tone: "waiting" },
  dropped: { label: "Dropped", tone: "quiet" },
};
const MONO = "ui-monospace, SFMono-Regular, Menlo, monospace";
const DAY = 86400000;
const EPISODES: Record<string, Episode> = Object.fromEntries(POSTS.episodes.map((episode) => [episode.id, episode] as const));
const BY_TIME = [...POSTS.posts].sort((a, b) => Date.parse(a.at) - Date.parse(b.at));

function zoned(iso: string, options: Intl.DateTimeFormatOptions, timeZone: string = POSTS.timeZone): Record<string, string> | null {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  const parts: Record<string, string> = {};
  for (const part of new Intl.DateTimeFormat("en-GB", { ...options, timeZone }).formatToParts(date)) parts[part.type] = part.value;
  return parts;
}

/** "Tue 27 Oct, 18:00", in the schedule's time zone. */
function when(iso: string): string {
  const p = zoned(iso, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  return p ? `${p.weekday} ${p.day} ${p.month}, ${p.hour}:${p.minute}` : iso;
}

/** "Tue 27 Oct". */
function dayOf(iso: string, timeZone: string = POSTS.timeZone): string {
  const p = zoned(iso, { weekday: "short", day: "numeric", month: "short" }, timeZone);
  return p ? `${p.weekday} ${p.day} ${p.month}` : iso;
}

/** "18:00". */
function timeOf(iso: string): string {
  const p = zoned(iso, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  return p ? `${p.hour}:${p.minute}` : iso;
}

/** The Monday that starts the week of `iso` in the schedule's time zone, as a UTC midnight. */
function weekOf(iso: string): number {
  const p = zoned(iso, { year: "numeric", month: "numeric", day: "numeric" });
  if (!p) return 0;
  const midnight = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day));
  return midnight - ((new Date(midnight).getUTCDay() + 6) % 7) * DAY;
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

function until(iso: string, now: number): string {
  const minutes = Math.round((Date.parse(iso) - now) / 60000);
  if (Number.isNaN(minutes)) return "";
  if (minutes < 60) return `in ${Math.max(minutes, 1)} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 36) return `in ${hours} h`;
  return `in ${Math.round(hours / 24)} days`;
}

function episodeName(id: string): string {
  const episode = EPISODES[id];
  return episode ? `${episode.id.toUpperCase()} ${episode.title}` : id.toUpperCase();
}

function hookLabel(post: Post): string {
  return `Hook ${post.hook.toUpperCase()}${post.trial ? ", trial reel, non-followers only" : ""}`;
}

function Dot({ tone }: { tone: Tone }) {
  const theme = useHostTheme();
  const color = { good: theme.category.green, waiting: theme.category.yellow, active: theme.accent.primary, quiet: theme.text.quaternary }[tone];
  return <span style={{ display: "inline-block", width: 8, height: 8, borderRadius: 4, background: color, flexShrink: 0 }} />;
}

function Status({ tone, label }: { tone: Tone; label: string }) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 6, minWidth: 0 }}>
      <Dot tone={tone} />
      <Text as="span" size="small" tone="secondary">
        {label}
      </Text>
    </span>
  );
}

/** A row that wraps when it must, with each item keeping its own width. */
function Inline({ gap = 8, align = "center", children }: { gap?: number; align?: "center" | "flex-start"; children: StackProps["children"] }) {
  return <div style={{ display: "flex", flexWrap: "wrap", alignItems: align, gap, minWidth: 0 }}>{children}</div>;
}

/** A dot beside text that may wrap. */
function Note({ tone, children }: { tone: Tone; children: string }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "8px minmax(0, 1fr)", gap: 8, alignItems: "start" }}>
      <div style={{ paddingTop: 4 }}>
        <Dot tone={tone} />
      </div>
      <Text size="small" tone="secondary">
        {children}
      </Text>
    </div>
  );
}

function Eyebrow({ children, accent }: { children: string; accent?: boolean }) {
  const theme = useHostTheme();
  return (
    <span style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.08em", textTransform: "uppercase", color: accent ? theme.accent.primary : theme.text.tertiary }}>
      {children}
    </span>
  );
}

/** Lines as they appear on screen. */
function Screen({ lines }: { lines: string[] }) {
  const theme = useHostTheme();
  return (
    <div
      style={{
        fontFamily: MONO,
        fontSize: 12,
        lineHeight: "17px",
        fontWeight: 600,
        letterSpacing: "0.03em",
        whiteSpace: "pre",
        padding: "8px 10px",
        borderRadius: 6,
        background: theme.fill.tertiary,
        color: theme.text.primary,
      }}
    >
      {lines.join("\n")}
    </div>
  );
}

function Lines({ label, lines }: { label: string; lines: string[] }) {
  return (
    <Stack gap={4}>
      <Eyebrow>{label}</Eyebrow>
      <Screen lines={lines} />
    </Stack>
  );
}

/** Text to paste elsewhere: a click selects all of it, and Copy puts it on the clipboard where the host allows. */
function CopyBlock({ text, mono = true }: { text: string; mono?: boolean }) {
  const theme = useHostTheme();
  const [said, setSaid] = useState<string | null>(null);
  const copy = () => {
    const fallback = "Click the text to select it, then press ⌘C";
    const clipboard = typeof navigator === "undefined" ? undefined : navigator.clipboard;
    if (!clipboard) {
      setSaid(fallback);
      return;
    }
    clipboard.writeText(text).then(
      () => setSaid("Copied"),
      () => setSaid(fallback),
    );
  };
  return (
    <Stack gap={6}>
      <div
        style={{
          fontFamily: mono ? MONO : undefined,
          fontSize: 12,
          lineHeight: "18px",
          whiteSpace: "pre-wrap",
          wordBreak: "break-word",
          userSelect: "all",
          padding: "10px 12px",
          borderRadius: 6,
          background: theme.fill.tertiary,
          color: theme.text.primary,
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

function Facts({ rows, labelWidth = 72 }: { rows: [string, string][]; labelWidth?: number }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: `${labelWidth}px minmax(0, 1fr)`, columnGap: 12, rowGap: 6 }}>
      {rows.map(([label, value]) => (
        <div key={label} style={{ display: "contents" }}>
          <Text size="small" tone="tertiary">
            {label}
          </Text>
          <Text size="small">{value}</Text>
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- platform states

/** Posted once the publisher's record has the post, whoever posted it; planned until then. */
function instagramState(post: Post): PlatformState {
  return PUBLISHED[post.id] ? "posted" : "planned";
}

function tiktokState(mark: TikTokMark | null): PlatformState {
  return mark?.state ?? "planned";
}

function PlatformStatus({ state }: { state: PlatformState }) {
  return <Status tone={PLATFORM_STATE[state].tone} label={PLATFORM_STATE[state].label} />;
}

function TikTokCell({ post }: { post: Post }) {
  const [mark] = useCanvasState<TikTokMark | null>(`tiktok:${post.id}`, null);
  return <PlatformStatus state={tiktokState(mark)} />;
}

/** A post's state on one platform; nothing when it doesn't go there. */
function PlatformCell({ post, platform }: { post: Post; platform: Platform }) {
  if (!post.platforms.includes(platform)) return null;
  return platform === "tiktok" ? <TikTokCell post={post} /> : <PlatformStatus state={instagramState(post)} />;
}

/** Each platform a post goes to, with its state. A parent that holds the TikTok mark passes it in. */
function PlatformList({ post, tiktok }: { post: Post; tiktok?: TikTokMark | null }) {
  return (
    <Inline gap={14}>
      {post.platforms.map((platform) => (
        <div key={platform}>
          <Inline gap={6}>
            <Text as="span" size="small" weight="medium">
              {NAME[platform]}
            </Text>
            {platform === "tiktok" && tiktok !== undefined ? (
              <PlatformStatus state={tiktokState(tiktok)} />
            ) : (
              <PlatformCell post={post} platform={platform} />
            )}
          </Inline>
        </div>
      ))}
    </Inline>
  );
}

// ---------------------------------------------------------------- Needs you

function settled(item: NeedsYouItem, mark?: Mark): boolean {
  return Boolean(item.done) || mark?.state === "done" || mark?.state === "skipped";
}

function NeedsYouRow({ item, mark, onMark }: { item: NeedsYouItem; mark?: Mark; onMark: (state: Mark["state"] | null) => void }) {
  const theme = useHostTheme();
  const dispatch = useCanvasAction();
  const closed = settled(item, mark);
  const ask = () => {
    onMark("asked");
    dispatch({
      type: "newComposerChat",
      userPrompt:
        `From the social room's Needs you list, please take on "${item.title}" (item ${item.id}): ${item.detail}` +
        `${item.command ? ` The command: ${item.command}` : ""} ` +
        "Use the redlamp-social skill (.cursor/skills/redlamp-social/SKILL.md), and update the social room canvas with what came of it.",
    });
  };
  return (
    <div style={{ display: "grid", gridTemplateColumns: "14px minmax(0, 1fr)", gap: 8, alignItems: "start", opacity: closed ? 0.6 : 1 }}>
      <div style={{ paddingTop: 6 }}>
        <Dot tone={closed ? "good" : item.blocking ? "waiting" : "quiet"} />
      </div>
      <Stack gap={3}>
        <Inline gap={8}>
          <Text as="span" size="small" weight="semibold">
            {item.title}
          </Text>
          {item.blocking && !closed ? <Pill size="sm">Blocks work</Pill> : null}
          {mark?.state === "asked" && !closed ? <Pill size="sm">With an agent</Pill> : null}
        </Inline>
        <Text size="small" tone="secondary">
          {item.detail}
        </Text>
        {item.unblocks ? (
          <Text size="small" tone="tertiary">
            {`Unblocks: ${item.unblocks}`}
          </Text>
        ) : null}
        {item.command && !closed ? (
          <div
            style={{
              fontFamily: MONO,
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
            {item.command}
          </div>
        ) : null}
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

function NeedsYou({ marks, setMarks }: { marks: Marks; setMarks: SetCanvasState<Marks> }) {
  const markItem = (id: string) => (state: Mark["state"] | null) =>
    setMarks((previous) => {
      const next = { ...previous };
      if (state) next[id] = { state, at: new Date().toISOString() };
      else delete next[id];
      return next;
    });
  const open = room.needsYou
    .filter((item) => !settled(item, marks[item.id]))
    .sort((a, b) => Number(Boolean(b.blocking)) - Number(Boolean(a.blocking)));
  const done = room.needsYou.filter((item) => settled(item, marks[item.id]));
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

// ---------------------------------------------------------------- Now

function NextPost({ post, first, now }: { post: Post; first: boolean; now: number }) {
  const theme = useHostTheme();
  const episode = EPISODES[post.episode];
  return (
    <Stack gap={10} style={{ flex: 1, minWidth: 0, padding: 14, borderRadius: 8, background: theme.fill.quaternary }}>
      <Row gap={8} align="center">
        <Eyebrow accent={first}>{first ? "Next" : "Then"}</Eyebrow>
        <Spacer />
        <Text size="small" tone="tertiary">
          {until(post.at, now)}
        </Text>
      </Row>
      <Stack gap={2}>
        <H2>{when(post.at)}</H2>
        <Text weight="semibold">{episodeName(post.episode)}</Text>
        <Text size="small" tone="secondary">
          {hookLabel(post)}
        </Text>
      </Stack>
      {episode ? <Screen lines={episode.hooks[post.hook]} /> : null}
      <PlatformList post={post} />
    </Stack>
  );
}

function CutState({ episode }: { episode: Episode }) {
  const [mark] = useCanvasState<Approval | null>(`cut:${episode.id}`, null);
  if (mark) return <Status tone={mark.state === "approved" ? "good" : "waiting"} label={mark.state === "approved" ? `Approved ${dayOf(mark.at)}` : "On hold"} />;
  if (episode.stage === "in review") return <Status tone="waiting" label="Waiting for you" />;
  if (episode.stage === "approved" || episode.stage === "rendered") return <Status tone="good" label="Approved" />;
  return (
    <Text size="small" tone="quaternary">
      Not built yet
    </Text>
  );
}

function Production() {
  return (
    <Table
      headers={["Video", "Stage", "Cut", "First post"]}
      rows={POSTS.episodes.map((episode) => {
        const first = BY_TIME.find((post) => post.episode === episode.id);
        return [
          episodeName(episode.id),
          <Status tone={STAGE[episode.stage].tone} label={STAGE[episode.stage].label} />,
          <CutState episode={episode} />,
          first ? dayOf(first.at) : "",
        ];
      })}
    />
  );
}

function NowTab({ now, marks, setMarks }: { now: number; marks: Marks; setMarks: SetCanvasState<Marks> }) {
  const upcoming = BY_TIME.filter((post) => Date.parse(post.at) > now).slice(0, 2);
  const side = room.needsYou.length > 0 || room.log.length > 0;
  return (
    <Grid columns={side ? "minmax(0, 1.55fr) minmax(0, 1fr)" : 1} gap={32} align="start">
      <Stack gap={26}>
        {upcoming.length > 0 && (
          <Stack gap={10}>
            <H3>Next posts</H3>
            <Grid columns={upcoming.length} gap={12} align="stretch">
              {upcoming.map((post, index) => (
                <div key={post.id} style={{ display: "flex", minWidth: 0 }}>
                  <NextPost post={post} first={index === 0} now={now} />
                </div>
              ))}
            </Grid>
          </Stack>
        )}
        {POSTS.episodes.length > 0 && (
          <Stack gap={10}>
            <H3>Production</H3>
            <Production />
          </Stack>
        )}
      </Stack>
      {side && (
        <Stack gap={20}>
          {room.needsYou.length > 0 && <NeedsYou marks={marks} setMarks={setMarks} />}
          {room.needsYou.length > 0 && room.log.length > 0 && <Divider />}
          {room.log.length > 0 && (
            <Stack gap={10}>
              <H3>Latest</H3>
              <LogEntries entries={room.log.slice(0, 2)} now={now} />
            </Stack>
          )}
        </Stack>
      )}
    </Grid>
  );
}

// ---------------------------------------------------------------- Schedule

const SCHEDULE_COLUMNS = "124px 52px minmax(0, 1fr) minmax(0, 1.2fr) 104px 104px";

function ScheduleTab({ now }: { now: number }) {
  const theme = useHostTheme();
  const next = BY_TIME.find((post) => Date.parse(post.at) > now);
  const weeks = new Map<number, Post[]>();
  for (const post of BY_TIME) weeks.set(weekOf(post.at), [...(weeks.get(weekOf(post.at)) ?? []), post]);
  const thisWeek = weekOf(new Date(now).toISOString());
  const row = { display: "grid", gridTemplateColumns: SCHEDULE_COLUMNS, columnGap: 12, alignItems: "center" } as const;
  return (
    <Stack gap={14}>
      <Text size="small" tone="secondary">
        {`Times are ${POSTS.timeZone}. TikTok's state is the one you mark in Posts; Instagram's comes from the publisher once it's built.`}
      </Text>
      <div style={{ ...row, paddingBottom: 6, borderBottom: `1px solid ${theme.stroke.secondary}` }}>
        {["Date", "Time", "Video", "Hook", "Instagram", "TikTok"].map((heading) => (
          <div key={heading}>
            <Eyebrow>{heading}</Eyebrow>
          </div>
        ))}
      </div>
      {Array.from(weeks.entries()).map(([week, posts]) => (
        <div key={week}>
          <Stack gap={0}>
            <Row gap={8} align="center" style={{ paddingBottom: 6 }}>
              <Text weight="semibold">{`${dayOf(new Date(week).toISOString(), "UTC")} to ${dayOf(new Date(week + 6 * DAY).toISOString(), "UTC")}`}</Text>
              {week === thisWeek ? <Pill size="sm">This week</Pill> : null}
              <Spacer />
              <Text size="small" tone="tertiary">
                {`${posts.length} ${posts.length === 1 ? "post" : "posts"}`}
              </Text>
            </Row>
            {posts.map((post) => (
              <div key={post.id} style={{ ...row, padding: "8px 0", borderTop: `1px solid ${theme.stroke.tertiary}` }}>
                <Inline gap={8}>
                  <Text as="span" size="small">
                    {dayOf(post.at)}
                  </Text>
                  {post === next ? <Eyebrow accent>Next</Eyebrow> : null}
                </Inline>
                <Text size="small" tone="secondary">
                  {timeOf(post.at)}
                </Text>
                <Text size="small">{episodeName(post.episode)}</Text>
                <Text size="small" tone="secondary">
                  {`${post.hook.toUpperCase()}${post.trial ? ", trial reel, non-followers only" : ""}`}
                </Text>
                <div>
                  <PlatformCell post={post} platform="instagram" />
                </div>
                <div>
                  <PlatformCell post={post} platform="tiktok" />
                </div>
              </div>
            ))}
          </Stack>
        </div>
      ))}
    </Stack>
  );
}

// ---------------------------------------------------------------- Posts

function CutControl({ episode }: { episode: Episode }) {
  const [mark, setMark] = useCanvasState<Approval | null>(`cut:${episode.id}`, null);
  const set = (state: Approval["state"] | null) => setMark(state === null ? null : { state, at: new Date().toISOString() });
  if (mark) {
    return (
      <Inline gap={8}>
        <Status tone={mark.state === "approved" ? "good" : "waiting"} label={`${mark.state === "approved" ? "Cut approved" : "Cut on hold"}, ${when(mark.at)}`} />
        <Button variant="ghost" onClick={() => set(null)}>
          Undo
        </Button>
      </Inline>
    );
  }
  if (episode.stage !== "in review") return null;
  return (
    <Inline gap={6}>
      <Button variant="secondary" onClick={() => set("approved")}>
        Approve cut
      </Button>
      <Button variant="ghost" onClick={() => set("held")}>
        Hold
      </Button>
    </Inline>
  );
}

function PostApproval({ post }: { post: Post }) {
  const [mark, setMark] = useCanvasState<Approval | null>(`post:${post.id}`, null);
  const changed = mark?.state === "approved" && mark.caption !== post.caption;
  const set = (state: Approval["state"] | null) =>
    setMark(state === null ? null : { state, at: new Date().toISOString(), ...(state === "approved" ? { caption: post.caption } : {}) });
  if (mark && !changed) {
    return (
      <Inline gap={8}>
        <Status tone={mark.state === "approved" ? "good" : "waiting"} label={`${mark.state === "approved" ? "Post approved" : "Post on hold"}, ${when(mark.at)}`} />
        <Button variant="ghost" onClick={() => set(null)}>
          Undo
        </Button>
      </Inline>
    );
  }
  return (
    <Inline gap={6}>
      <Button variant="secondary" onClick={() => set("approved")}>
        Approve post
      </Button>
      <Button variant="ghost" onClick={() => set("held")}>
        Hold
      </Button>
      {changed ? (
        <Text as="span" size="small" tone="tertiary">
          The caption has changed since you approved it.
        </Text>
      ) : null}
    </Inline>
  );
}

function TikTokControls({
  mark,
  setMark,
  link,
  setLink,
}: {
  mark: TikTokMark | null;
  setMark: SetCanvasState<TikTokMark | null>;
  link: string;
  setLink: SetCanvasState<string>;
}) {
  const set = (state: TikTokMark["state"] | null) => setMark(state === null ? null : { state, at: new Date().toISOString() });
  return (
    <Stack gap={8}>
      <Inline gap={6}>
        <Text as="span" size="small" weight="semibold">
          TikTok
        </Text>
        {mark ? (
          <>
            <Status tone={PLATFORM_STATE[mark.state].tone} label={`${PLATFORM_STATE[mark.state].label}, marked ${when(mark.at)}`} />
            {mark.state === "scheduled" ? (
              <Button variant="secondary" onClick={() => set("posted")}>
                Posted
              </Button>
            ) : null}
            <Button variant="ghost" onClick={() => set(null)}>
              Undo
            </Button>
          </>
        ) : (
          <>
            <Button variant="secondary" onClick={() => set("scheduled")}>
              Scheduled
            </Button>
            <Button variant="ghost" onClick={() => set("posted")}>
              Posted
            </Button>
            <Button variant="ghost" onClick={() => set("skipped")}>
              Skipped
            </Button>
          </>
        )}
      </Inline>
      {mark && mark.state !== "skipped" ? (
        <Row gap={8} align="center">
          <TextInput value={link} onChange={(value) => setLink(value)} type="url" placeholder="The post's TikTok link" style={{ width: 360 }} />
          {link.startsWith("https://") ? <Link href={link}>Open</Link> : null}
        </Row>
      ) : null}
    </Stack>
  );
}

function PostBlock({ post }: { post: Post }) {
  const [tiktok, setTikTok] = useCanvasState<TikTokMark | null>(`tiktok:${post.id}`, null);
  const [link, setLink] = useCanvasState<string>(`link:${post.id}:tiktok`, "");
  return (
    <Stack gap={10}>
      <Divider />
      <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) auto", gap: 12, alignItems: "center" }}>
        <Inline gap={10}>
          <Text as="span" weight="semibold">
            {when(post.at)}
          </Text>
          <Text as="span" size="small" tone="secondary">
            {hookLabel(post)}
          </Text>
        </Inline>
        <PlatformList post={post} tiktok={tiktok} />
      </div>
      {post.check ? <Note tone="waiting">{`Check: ${post.check}`}</Note> : null}
      <CopyBlock text={post.caption} />
      <CollapsibleSection title="Alt text">
        <CopyBlock text={post.alt} mono={false} />
      </CollapsibleSection>
      <Text size="small" tone="tertiary">
        {`${post.file}, cover frame at ${(post.coverMs / 1000).toFixed(1)} s`}
      </Text>
      <PostApproval post={post} />
      {post.platforms.includes("tiktok") ? <TikTokControls mark={tiktok} setMark={setTikTok} link={link} setLink={setLink} /> : null}
    </Stack>
  );
}

function EpisodeSection({ episode, first }: { episode: Episode; first: boolean }) {
  const theme = useHostTheme();
  const posts = BY_TIME.filter((post) => post.episode === episode.id);
  const images = [
    { key: `${episode.id}-hook`, label: "Hook frame" },
    { key: `${episode.id}-result`, label: "Result frame" },
  ].filter((image) => THUMBS[image.key]);
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: images.length > 0 ? `${images.length * 116 - 8}px minmax(0, 1fr)` : "minmax(0, 1fr)",
        gap: 20,
        padding: "20px 0",
        borderTop: first ? `1px solid ${theme.stroke.tertiary}` : undefined,
        borderBottom: `1px solid ${theme.stroke.tertiary}`,
      }}
    >
      {images.length > 0 ? (
        <Grid columns={images.length} gap={8} align="start">
          {images.map((image) => (
            <div key={image.key}>
              <Stack gap={4}>
                <img
                  src={THUMBS[image.key]}
                  alt={`${image.label} of ${episode.title}`}
                  style={{
                    display: "block",
                    width: "100%",
                    aspectRatio: "9 / 16",
                    objectFit: "cover",
                    imageRendering: "pixelated",
                    borderRadius: 4,
                    border: `1px solid ${theme.stroke.tertiary}`,
                  }}
                />
                <Text size="small" tone="tertiary">
                  {image.label}
                </Text>
              </Stack>
            </div>
          ))}
        </Grid>
      ) : null}
      <Stack gap={14}>
        <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) auto", gap: 12, alignItems: "center" }}>
          <Inline gap={12}>
            <H3>{episodeName(episode.id)}</H3>
            <Status tone={STAGE[episode.stage].tone} label={STAGE[episode.stage].label} />
          </Inline>
          <CutControl episode={episode} />
        </div>
        <Facts
          rows={[
            ["Feature", episode.feature],
            ["Audience", episode.audience],
            ["Source", episode.source],
            ["Result", episode.result],
          ]}
        />
        <Inline gap={12} align="flex-start">
          <div>
            <Lines label="Hook A" lines={episode.hooks.a} />
          </div>
          <div>
            <Lines label="Hook B" lines={episode.hooks.b} />
          </div>
          <div>
            <Lines label="End line" lines={episode.endLine} />
          </div>
        </Inline>
        {posts.map((post) => (
          <div key={post.id}>
            <PostBlock post={post} />
          </div>
        ))}
      </Stack>
    </div>
  );
}

function PostsTab() {
  const [selected, setSelected] = useCanvasState<string>("episode", "all");
  const known = POSTS.episodes.some((episode) => episode.id === selected);
  const episodes = known ? POSTS.episodes.filter((episode) => episode.id === selected) : POSTS.episodes;
  return (
    <Stack gap={18}>
      {POSTS.episodes.length > 1 && (
        <Row gap={6} wrap>
          <span>
            <Pill active={!known} onClick={() => setSelected("all")}>
              All
            </Pill>
          </span>
          {POSTS.episodes.map((episode) => (
            <span key={episode.id}>
              <Pill active={selected === episode.id} onClick={() => setSelected(episode.id)}>
                {episode.title}
              </Pill>
            </span>
          ))}
        </Row>
      )}
      <Stack gap={0}>
        {episodes.map((episode, index) => (
          <div key={episode.id}>
            <EpisodeSection episode={episode} first={index === 0} />
          </div>
        ))}
      </Stack>
    </Stack>
  );
}

// ---------------------------------------------------------------- Platforms, Plan, Log

function PlatformsTab() {
  const instagram = POSTS.posts.filter((post) => post.platforms.includes("instagram"));
  const trials = instagram.filter((post) => post.trial).length;
  const tiktok = POSTS.posts.filter((post) => post.platforms.includes("tiktok")).length;
  const about: Record<Platform, { how: string; schedule: string; allows: string }> = {
    instagram: {
      how: "Through Instagram's API, by the publisher: room.py publish, and room.py tick every 15 minutes under a launchd agent, post each approved Reel and trial reel at its time. The publisher isn't built yet, so nothing goes to Instagram until it is.",
      schedule: `${instagram.length - trials} Reels and ${trials} trial reels`,
      allows:
        "Reels on a professional account, with a caption, a cover and an audio name, uploaded from the Mac; trial reels, which only non-followers see; 100 API-published posts in a moving 24 hours; no scheduling of its own.",
    },
    tiktok: {
      how: "Scheduled by you in TikTok Studio on the web, from the captions in Posts. Mark each post Scheduled, then Posted with its link.",
      schedule: `${tiktok} posts`,
      allows:
        "Posts from apps TikTok hasn't audited stay private, and its guidelines rule out a tool that uploads to accounts you manage, so posts are scheduled by hand. About 15 posts a day per creator.",
    },
  };
  const platforms: Platform[] = ["instagram", "tiktok"];
  return (
    <Grid columns={2} gap={16} align="start">
      {platforms.map((platform) => {
        const account = room.platforms[platform];
        const rows: [string, string][] = [];
        if (account.account) rows.push(["Account", account.account]);
        rows.push(
          ["Connection", account.connection],
          ["How posts go out", about[platform].how],
          ["In the schedule", about[platform].schedule],
          ["What it allows", about[platform].allows],
        );
        return (
          <div key={platform}>
            <Card>
              <CardHeader>{NAME[platform]}</CardHeader>
              <CardBody>
                <Facts rows={rows} labelWidth={112} />
              </CardBody>
            </Card>
          </div>
        );
      })}
    </Grid>
  );
}

function PlanTab() {
  const theme = useHostTheme();
  return (
    <Stack gap={0}>
      {room.plan.map((step, index) => (
        <div
          key={step.id}
          style={{
            display: "grid",
            gridTemplateColumns: "28px minmax(0, 1fr) 116px",
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
          <Status tone={STEP[step.status].tone} label={STEP[step.status].label} />
        </div>
      ))}
    </Stack>
  );
}

function LogEntries({ entries, now }: { entries: Room["log"]; now: number }) {
  return (
    <Stack gap={12}>
      {entries.map((entry) => (
        <div key={`${entry.at}-${entry.text.slice(0, 32)}`} style={{ display: "grid", gridTemplateColumns: "120px minmax(0, 1fr)", gap: 10 }}>
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

export default function SocialRoom() {
  const now = useNow();
  const [marks, setMarks] = useCanvasState<Marks>("needsYou", {});
  const [selected, setSelected] = useCanvasState<Tab>("tab", "Now");
  const shown: Record<Tab, boolean> = {
    Now: true,
    Schedule: POSTS.posts.length > 0,
    Posts: POSTS.episodes.length > 0,
    Platforms: true,
    Plan: room.plan.length > 0,
    Log: room.log.length > 0,
    Decisions: room.decisions.length > 0,
  };
  const tabs = TABS.filter((tab) => shown[tab]);
  const tab: Tab = shown[selected] ? selected : "Now";
  const open = room.needsYou.filter((item) => !settled(item, marks[item.id]));
  const blocking = open.filter((item) => item.blocking).length;
  const next = BY_TIME.find((post) => Date.parse(post.at) > now);
  return (
    <Stack gap={18} style={{ padding: 4 }}>
      <Stack gap={6}>
        <Row gap={10} align="center">
          <H1>Social room</H1>
          <Pill size="sm">{room.status}</Pill>
        </Row>
        <Text>{room.summary}</Text>
        <Text size="small" tone="tertiary">
          {`Updated ${ago(room.updated, now)} (${when(room.updated)})`}
        </Text>
      </Stack>

      <Row gap={32} wrap>
        <Stat value={`${POSTS.episodes.length}`} label="Videos planned" />
        <Stat value={`${POSTS.posts.length}`} label="Posts in the schedule" />
        {next ? <Stat value={dayOf(next.at)} label={`Next post: ${episodeName(next.episode)}, ${timeOf(next.at)}`} /> : null}
        {room.needsYou.length > 0 ? (
          <Stat
            value={`${open.length}`}
            label={blocking > 0 ? `Waiting on you, ${blocking} blocking` : "Waiting on you"}
            tone={blocking > 0 ? "warning" : undefined}
          />
        ) : null}
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

      {tab === "Now" && <NowTab now={now} marks={marks} setMarks={setMarks} />}
      {tab === "Schedule" && <ScheduleTab now={now} />}
      {tab === "Posts" && <PostsTab />}
      {tab === "Platforms" && <PlatformsTab />}
      {tab === "Plan" && <PlanTab />}
      {tab === "Log" && <LogEntries entries={room.log} now={now} />}
      {tab === "Decisions" && (
        <Table
          headers={["Date", "Decision", "Why", "By"]}
          rows={room.decisions.map((d) => [<span style={{ whiteSpace: "nowrap" }}>{dayOf(`${d.date}T12:00:00Z`, "UTC")}</span>, d.decision, d.why, d.by])}
          striped
        />
      )}
      <Text size="small" tone="tertiary">
        {`Schedule: docs/social/posts.json · Campaign: ${POSTS.campaign.doc} · Skill: .cursor/skills/redlamp-social/SKILL.md`}
      </Text>
    </Stack>
  );
}
