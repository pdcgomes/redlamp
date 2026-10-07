import {
  Button,
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
  useCanvasAction,
  useCanvasState,
  useEffect,
  useHostTheme,
  useState,
} from "cursor/canvas";
import type { SetCanvasState } from "cursor/canvas";

// The blog room (.cursor/skills/redlamp-blog/SKILL.md): every redlamp.app post from idea to
// announcement, each post's social kit, and what has been posted where. Edit only `room` below;
// room.py thumbs writes THUMBS. An empty list hides its section or tab.

type Stage = "idea" | "promised" | "collecting" | "facts ready" | "drafting" | "draft";
type ShareState = "draft" | "scheduled" | "unconfirmed" | "posted" | "skipped";
type PostedState = "posted" | "scheduled" | "unconfirmed" | "drafted" | "listed" | "couldn't post";

interface NeedsYouItem {
  id: string;
  title: string;
  /** Exactly what to do and where; once done, "Done: …" with what came of it. */
  detail: string;
  unblocks: string;
  blocking: boolean;
  done: boolean;
  /** A share's ID: the item then takes that share's buttons (Posted, Scheduled, Not posted, Skip). */
  share?: string;
  command?: string;
}

interface Share {
  /** Unique in the room, as "x-<slug>"; the owner's marks are kept by it. */
  id: string;
  channel: string;
  state: ShareState;
  /** When it went out or is due, as recorded. */
  when?: string;
  /** What to attach, from the kit. */
  media?: string;
  /** The copy, word for word from the kit's posts.md. */
  text?: string;
  alternative?: string;
  /** Characters as X counts them (a link is 23), or words. */
  count?: string;
  /** Where it is on the platform, once posted. */
  link?: string;
  note?: string;
}

interface Post {
  slug: string;
  title: string;
  /** From the front matter. */
  published: string;
  summary: string;
  /** The commit that published it, and later ones that changed it. */
  commits: string;
  /** The kit's files in docs/blog/social/<slug>/; `open: false` for what Cursor can't show. */
  kit: { label: string; path: string; open?: boolean }[];
  /** The post's own images, beside its index.md. */
  images: string[];
  shares: Share[];
  chat?: { title: string; id: string };
  note?: string;
}

interface Planned {
  id: string;
  title: string;
  stage: Stage;
  why: string;
  material: string;
  waitsOn: string;
  chat?: { title: string; id: string };
}

interface Posted {
  date: string;
  channel: string;
  what: string;
  state: PostedState;
  /** What the record rests on: the owner's word in a chat, a link, or only a draft. */
  source: string;
  link?: string;
  chat?: string;
}

interface Room {
  /** ISO with the time zone. */
  updated: string;
  /** Where the blog stands, in two or three sentences. */
  summary: string;
  /** The published post to announce next, by slug. */
  upNext?: string;
  needsYou: NeedsYouItem[];
  /** Published posts, newest first. */
  posts: Post[];
  pipeline: Planned[];
  /** Everything posted to announce Redlamp or a post, newest first. */
  posted: Posted[];
  /** Dates and work outside the blog that touch it. */
  elsewhere: { title: string; detail: string }[];
  /** Newest first. */
  log: { at: string; text: string }[];
  decisions: { date: string; decision: string; why: string; by: "Owner" | "Default" }[];
  links: { label: string; target: string }[];
}

const REPO = "/Users/pedrogomes/src/darkroom";
const kitFiles = (slug: string, downloads: string): Post["kit"] => [
  { label: "Card, animated, for X", path: `${REPO}/docs/blog/social/${slug}/card.gif` },
  { label: "Card, still", path: `${REPO}/docs/blog/social/${slug}/card.png` },
  { label: "Card as a video, for LinkedIn", path: `${REPO}/docs/blog/social/${slug}/card.mp4`, open: false },
  { label: "The copy and alt text", path: `${REPO}/docs/blog/social/${slug}/posts.md` },
  { label: "Copies to post from (Finder only)", path: downloads, open: false },
];

const room: Room = {
  updated: "2026-10-07T10:55:00+01:00",
  summary: "Example: four posts are live, one is ready to announce, and two are in the pipeline.",
  upNext: "example-post",
  needsYou: [
    {
      id: "announce-example-x",
      share: "x-example-post",
      title: "Post Example post on X",
      detail: "Example: copy the X post from Up next, attach card.gif, then press Posted or Scheduled.",
      unblocks: "The post's announcement",
      blocking: false,
      done: false,
    },
  ],
  posts: [
    {
      slug: "example-post",
      title: "Example post",
      published: "2026-10-05",
      summary: "Example: the post's summary, from its front matter.",
      commits: "Published in 0000000",
      kit: kitFiles("example-post", "~/Downloads/redlamp-example-post.gif, .png and .mp4"),
      images: [],
      shares: [
        {
          id: "x-example-post",
          channel: "X",
          state: "draft",
          media: "card.gif",
          count: "250 of 280 characters",
          text: "Redlamp is a free, open-source raw editor for the Mac that works like Lightroom.\n\nExample.\n\nhttps://redlamp.app/blog/example-post",
        },
      ],
    },
  ],
  pipeline: [
    {
      id: "example-next",
      title: "Example: the next post",
      stage: "idea",
      why: "Example: why it's on the list, and who asked for it.",
      material: "Example: where its material is.",
      waitsOn: "Example: what it waits on.",
    },
  ],
  posted: [
    {
      date: "2026-10-05",
      channel: "X",
      what: "Example post, with its card",
      state: "posted",
      source: "Example: the owner's mark in the room",
    },
  ],
  elsewhere: [],
  log: [{ at: "2026-10-07T10:55:00+01:00", text: "Example." }],
  decisions: [],
  links: [{ label: "Skill", target: ".cursor/skills/redlamp-blog/SKILL.md" }],
};

// THUMBS:BEGIN (room.py thumbs writes this block from docs/blog/social/*/thumb.jpg)
const THUMBS: Record<string, string> = {};
// THUMBS:END

// ---------------------------------------------------------------- rendering (keys sit on wrapper divs)

const TABS = ["Overview", "Posts", "Pipeline", "Posted", "Log", "Decisions"] as const;
type Tab = (typeof TABS)[number];
type Tone = "good" | "bad" | "waiting" | "active" | "quiet";

type Mark = { state: "done" | "skipped" | "asked"; at: string };
type Marks = Record<string, Mark>;
type ShareMark = { state: "posted" | "scheduled" | "draft" | "skipped"; at: string };
type ShareMarks = Record<string, ShareMark>;

const SHARE_TONE: Record<ShareState, Tone> = {
  posted: "good",
  scheduled: "active",
  unconfirmed: "waiting",
  draft: "waiting",
  skipped: "quiet",
};
const SHARE_LABEL: Record<ShareState, string> = {
  posted: "Posted",
  scheduled: "Scheduled",
  unconfirmed: "Not confirmed",
  draft: "Ready to post",
  skipped: "Not posting",
};
const POSTED_TONE: Record<PostedState, Tone> = {
  posted: "good",
  listed: "good",
  scheduled: "active",
  unconfirmed: "waiting",
  drafted: "quiet",
  "couldn't post": "bad",
};
const STAGE_TONE: Record<Stage, Tone> = {
  draft: "active",
  drafting: "active",
  "facts ready": "good",
  collecting: "waiting",
  promised: "waiting",
  idea: "quiet",
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

function day(date: string): string {
  const parsed = new Date(`${date}T12:00:00`);
  if (Number.isNaN(parsed.getTime())) return date;
  return parsed.toLocaleDateString(undefined, { day: "numeric", month: "short" });
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

function Thumb({ slug, alt, width }: { slug: string; alt: string; width: number }) {
  const theme = useHostTheme();
  const src = THUMBS[slug];
  if (!src) return null;
  return (
    <img
      src={src}
      alt={alt}
      style={{ display: "block", width: "100%", maxWidth: width, aspectRatio: "16 / 9", borderRadius: 6, border: `1px solid ${theme.stroke.tertiary}` }}
    />
  );
}

function OpenFiles({ files }: { files: { label: string; path: string; open?: boolean }[] }) {
  const dispatch = useCanvasAction();
  return (
    <Stack gap={6}>
      {files.map((file) => (
        <div key={file.path} style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) auto", gap: 8, alignItems: "center" }}>
          <Stack gap={0}>
            <Text size="small" weight="medium">
              {file.label}
            </Text>
            <Text size="small" tone="tertiary" truncate="start">
              {file.path.replace(`${REPO}/`, "")}
            </Text>
          </Stack>
          {file.open === false ? null : (
            <Button variant="ghost" onClick={() => dispatch({ type: "openFile", path: file.path })}>
              Open
            </Button>
          )}
        </div>
      ))}
    </Stack>
  );
}

function allShares(): Share[] {
  return room.posts.flatMap((post) => post.shares);
}

/** The owner's mark on a share while the room hasn't recorded it: one made after the room's last update. */
function pendingMark(share: Share, marks: ShareMarks): ShareMark | undefined {
  const mark = marks[share.id];
  return mark && Date.parse(mark.at) > Date.parse(room.updated) ? mark : undefined;
}

function shareState(share: Share, marks: ShareMarks): ShareState {
  return pendingMark(share, marks)?.state ?? share.state;
}

/** The buttons a share takes in its state; a mark from the owner shows instead, with Undo. */
function ShareButtons({ share, marks, setMarks }: { share: Share; marks: ShareMarks; setMarks: SetCanvasState<ShareMarks> }) {
  const mark = pendingMark(share, marks);
  const set = (state: ShareMark["state"] | null) =>
    setMarks((previous) => {
      const next = { ...previous };
      if (state) next[share.id] = { state, at: new Date().toISOString() };
      else delete next[share.id];
      return next;
    });
  if (mark) {
    const said = { posted: "Marked posted", scheduled: "Marked scheduled", draft: "Marked not posted", skipped: "Skipped" }[mark.state];
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
  if (share.state === "posted" || share.state === "skipped") return null;
  return (
    <Row gap={6}>
      <Button variant="secondary" onClick={() => set("posted")}>
        Posted
      </Button>
      {share.state === "draft" ? (
        <>
          <Button variant="ghost" onClick={() => set("scheduled")}>
            Scheduled
          </Button>
          <Button variant="ghost" onClick={() => set("skipped")}>
            Skip
          </Button>
        </>
      ) : (
        <Button variant="ghost" onClick={() => set("draft")}>
          Not posted
        </Button>
      )}
    </Row>
  );
}

function ShareBlock({ share, marks, setMarks, copy }: { share: Share; marks: ShareMarks; setMarks: SetCanvasState<ShareMarks>; copy: boolean }) {
  const state = shareState(share, marks);
  const facts = [share.when, share.media ? `attach ${share.media}` : undefined, share.count].filter(Boolean).join(" · ");
  return (
    <Stack gap={8}>
      <div style={{ display: "grid", gridTemplateColumns: "auto auto minmax(0, 1fr)", gap: 12, alignItems: "center" }}>
        <Text weight="semibold">{share.channel}</Text>
        <Status tone={SHARE_TONE[state]} label={SHARE_LABEL[state]} />
        <Text size="small" tone="tertiary" style={{ textAlign: "right" }}>
          {facts}
        </Text>
      </div>
      {share.note ? (
        <Text size="small" tone="secondary">
          {share.note}
        </Text>
      ) : null}
      {share.link ? <Link href={share.link}>{share.link}</Link> : null}
      {copy && share.text ? <CopyText text={share.text} /> : null}
      {copy && share.alternative ? (
        <CollapsibleSection title="The alternative">
          <CopyText text={share.alternative} />
        </CollapsibleSection>
      ) : null}
      <ShareButtons share={share} marks={marks} setMarks={setMarks} />
    </Stack>
  );
}

function settled(item: NeedsYouItem, marks: Marks, shareMarks: ShareMarks): boolean {
  if (item.done) return true;
  if (item.share) {
    const share = allShares().find((candidate) => candidate.id === item.share);
    const state = share ? shareState(share, shareMarks) : "posted";
    return state === "posted" || state === "scheduled" || state === "skipped" || (share !== undefined && pendingMark(share, shareMarks)?.state === "draft");
  }
  const state = marks[item.id]?.state;
  return state === "done" || state === "skipped";
}

function NeedsYouRow({
  item,
  marks,
  setMarks,
  shareMarks,
  setShareMarks,
}: {
  item: NeedsYouItem;
  marks: Marks;
  setMarks: SetCanvasState<Marks>;
  shareMarks: ShareMarks;
  setShareMarks: SetCanvasState<ShareMarks>;
}) {
  const dispatch = useCanvasAction();
  const closed = settled(item, marks, shareMarks);
  const mark = marks[item.id];
  const share = item.share ? allShares().find((candidate) => candidate.id === item.share) : undefined;
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
        `From the blog room's Needs you list, please take on "${item.title}" (item ${item.id}): ${item.detail}` +
        `${item.command ? ` The command: ${item.command}` : ""} ` +
        "Follow .cursor/skills/redlamp-blog/SKILL.md, and update the blog room with what came of it.",
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
          {item.blocking && !closed ? <Pill size="sm">Blocks work</Pill> : null}
          {mark?.state === "asked" && !closed ? <Pill size="sm">With an agent</Pill> : null}
        </Row>
        <Text size="small" tone="secondary">
          {item.detail}
        </Text>
        <Text size="small" tone="tertiary">
          {`Unblocks: ${item.unblocks}`}
        </Text>
        {share ? (
          <div style={{ paddingTop: 4 }}>
            <ShareButtons share={share} marks={shareMarks} setMarks={setShareMarks} />
          </div>
        ) : null}
        {!share && !item.done && mark && mark.state !== "asked" ? (
          <Row gap={8} align="center">
            <Text size="small" tone="tertiary">
              {`${mark.state === "done" ? "Marked done by you" : "Skipped"}, ${when(mark.at)}; the agent picks it up at its next update.`}
            </Text>
            <Button variant="ghost" onClick={() => set(null)}>
              Undo
            </Button>
          </Row>
        ) : null}
        {!share && !closed ? (
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

function NeedsYou(props: { marks: Marks; setMarks: SetCanvasState<Marks>; shareMarks: ShareMarks; setShareMarks: SetCanvasState<ShareMarks> }) {
  const open = room.needsYou.filter((item) => !settled(item, props.marks, props.shareMarks)).sort((a, b) => Number(b.blocking) - Number(a.blocking));
  const done = room.needsYou.filter((item) => settled(item, props.marks, props.shareMarks));
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
          <NeedsYouRow item={item} {...props} />
        </div>
      ))}
      {done.length > 0 && (
        <CollapsibleSection title="Done" count={done.length} defaultOpen={open.length === 0}>
          <Stack gap={10}>
            {done.map((item) => (
              <div key={item.id}>
                <NeedsYouRow item={item} {...props} />
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

function UpNext({ post, marks, setMarks }: { post: Post; marks: ShareMarks; setMarks: SetCanvasState<ShareMarks> }) {
  const shares = post.shares.filter((share) => share.state !== "posted" && share.state !== "skipped");
  return (
    <Stack gap={16}>
      <Stack gap={4}>
        <Eyebrow>Up next</Eyebrow>
        <H2>{`Announce ${post.title}`}</H2>
        <Text size="small" tone="secondary">
          {`Published ${day(post.published)} at redlamp.app/blog/${post.slug}`}
        </Text>
      </Stack>
      <Grid columns={THUMBS[post.slug] ? "minmax(0, 320px) minmax(0, 1fr)" : 1} gap={18} align="start">
        {THUMBS[post.slug] ? <Thumb slug={post.slug} alt={`The card for ${post.title}`} width={320} /> : null}
        <OpenFiles files={post.kit} />
      </Grid>
      {shares.map((share, index) => (
        <div key={share.id}>
          <Stack gap={14}>
            {index > 0 ? <Divider /> : null}
            <ShareBlock share={share} marks={marks} setMarks={setMarks} copy />
          </Stack>
        </div>
      ))}
    </Stack>
  );
}

function EveryPost({ marks }: { marks: ShareMarks }) {
  const channels = Array.from(new Set(room.posts.flatMap((post) => post.shares.map((share) => share.channel))));
  return (
    <Table
      headers={["Post", "Published", ...channels]}
      rows={room.posts.map((post) => [
        post.title,
        day(post.published),
        ...channels.map((channel) => {
          const share = post.shares.find((candidate) => candidate.channel === channel);
          if (!share) return <Text size="small" tone="quaternary">None</Text>;
          const state = shareState(share, marks);
          return <Status tone={SHARE_TONE[state]} label={SHARE_LABEL[state]} />;
        }),
      ])}
    />
  );
}

function OverviewTab(props: { now: number; marks: Marks; setMarks: SetCanvasState<Marks>; shareMarks: ShareMarks; setShareMarks: SetCanvasState<ShareMarks> }) {
  const next = room.posts.find((post) => post.slug === room.upNext);
  return (
    <Grid columns="minmax(0, 1.55fr) minmax(0, 1fr)" gap={32} align="start">
      <Stack gap={28}>
        {next ? <UpNext post={next} marks={props.shareMarks} setMarks={props.setShareMarks} /> : null}
        <Stack gap={10}>
          <H3>Every post</H3>
          <EveryPost marks={props.shareMarks} />
        </Stack>
      </Stack>
      <Stack gap={20}>
        {room.needsYou.length > 0 && <NeedsYou {...props} />}
        {room.log.length > 0 && (
          <>
            <Divider />
            <Stack gap={10}>
              <H3>Latest</H3>
              <LogEntries entries={room.log.slice(0, 2)} now={props.now} />
            </Stack>
          </>
        )}
      </Stack>
    </Grid>
  );
}

function PostsTab({ marks, setMarks }: { marks: ShareMarks; setMarks: SetCanvasState<ShareMarks> }) {
  const theme = useHostTheme();
  const dispatch = useCanvasAction();
  return (
    <Stack gap={0}>
      {room.posts.map((post, index) => (
        <div
          key={post.slug}
          style={{
            display: "grid",
            gridTemplateColumns: THUMBS[post.slug] ? "240px minmax(0, 1fr)" : "minmax(0, 1fr)",
            gap: 20,
            padding: "18px 0",
            borderTop: index === 0 ? `1px solid ${theme.stroke.tertiary}` : undefined,
            borderBottom: `1px solid ${theme.stroke.tertiary}`,
          }}
        >
          {THUMBS[post.slug] ? <Thumb slug={post.slug} alt={`The card for ${post.title}`} width={240} /> : null}
          <Stack gap={10}>
            <Row gap={8} align="center">
              <Text weight="semibold">{post.title}</Text>
              <Spacer />
              <Text size="small" tone="tertiary">
                {day(post.published)}
              </Text>
            </Row>
            <Text size="small" tone="secondary">
              {post.summary}
            </Text>
            <Text size="small" tone="tertiary">
              {`redlamp.app/blog/${post.slug} · ${post.commits}`}
            </Text>
            {post.note ? <Text size="small">{post.note}</Text> : null}
            {post.shares.map((share) => (
              <div key={share.id}>
                <ShareBlock share={share} marks={marks} setMarks={setMarks} copy={false} />
              </div>
            ))}
            {post.shares.some((share) => share.text) ? (
              <CollapsibleSection title="The copy">
                <Stack gap={12}>
                  {post.shares
                    .filter((share) => share.text)
                    .map((share) => (
                      <div key={share.id}>
                        <Stack gap={6}>
                          <Text size="small" weight="semibold">
                            {share.channel}
                          </Text>
                          <CopyText text={share.text ?? ""} />
                          {share.alternative ? <CopyText text={share.alternative} /> : null}
                        </Stack>
                      </div>
                    ))}
                </Stack>
              </CollapsibleSection>
            ) : null}
            {post.kit.length > 0 ? (
              <CollapsibleSection title="The kit" count={post.kit.length}>
                <OpenFiles files={post.kit} />
              </CollapsibleSection>
            ) : null}
            {post.images.length > 0 ? (
              <CollapsibleSection title="The post's own images" count={post.images.length}>
                <OpenFiles files={post.images.map((name) => ({ label: name, path: `${REPO}/web/content/blog/${post.slug}/${name}` }))} />
              </CollapsibleSection>
            ) : null}
            {post.chat ? (
              <Row>
                <Button variant="ghost" onClick={() => dispatch({ type: "openAgent", agentId: post.chat?.id ?? "" })}>
                  {`Open the chat that wrote it: ${post.chat.title}`}
                </Button>
              </Row>
            ) : null}
          </Stack>
        </div>
      ))}
    </Stack>
  );
}

function PipelineTab() {
  const theme = useHostTheme();
  const dispatch = useCanvasAction();
  return (
    <Stack gap={22}>
      <Stack gap={0}>
        {room.pipeline.map((item, index) => (
          <div
            key={item.id}
            style={{
              display: "grid",
              gridTemplateColumns: "minmax(0, 1fr) 130px",
              gap: 16,
              alignItems: "start",
              padding: "12px 0",
              borderTop: index === 0 ? `1px solid ${theme.stroke.tertiary}` : undefined,
              borderBottom: `1px solid ${theme.stroke.tertiary}`,
            }}
          >
            <Stack gap={4}>
              <Text weight="semibold">{item.title}</Text>
              <Text size="small" tone="secondary">
                {item.why}
              </Text>
              <Text size="small" tone="tertiary">
                {`Material: ${item.material}`}
              </Text>
              <Text size="small">{`Waits on: ${item.waitsOn}`}</Text>
              {item.chat ? (
                <Row>
                  <Button variant="ghost" onClick={() => dispatch({ type: "openAgent", agentId: item.chat?.id ?? "" })}>
                    {`Open ${item.chat.title}`}
                  </Button>
                </Row>
              ) : null}
            </Stack>
            <Status tone={STAGE_TONE[item.stage]} label={item.stage} />
          </div>
        ))}
      </Stack>
      {room.elsewhere.length > 0 && (
        <Stack gap={10}>
          <H3>Coming up elsewhere</H3>
          {room.elsewhere.map((item) => (
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
    </Stack>
  );
}

function PostedTab() {
  const dispatch = useCanvasAction();
  return (
    <Stack gap={10}>
      <Text size="small" tone="secondary">
        Everything posted to announce Redlamp or a post, newest first. Each row says what the record rests on: your word in a chat, a link, or only a draft.
      </Text>
      <Table
        headers={["Date", "Where", "What", "State", "Recorded from"]}
        rows={room.posted.map((entry) => [
          <span style={{ whiteSpace: "nowrap" }}>{day(entry.date)}</span>,
          entry.channel,
          entry.link ? <Link href={entry.link}>{entry.what}</Link> : entry.what,
          <span style={{ whiteSpace: "nowrap" }}>
            <Status tone={POSTED_TONE[entry.state]} label={entry.state} />
          </span>,
          entry.chat ? (
            <Stack gap={2}>
              <Text size="small" tone="secondary">
                {entry.source}
              </Text>
              <div>
                <Button variant="ghost" onClick={() => dispatch({ type: "openAgent", agentId: entry.chat ?? "" })}>
                  Open the chat
                </Button>
              </div>
            </Stack>
          ) : (
            entry.source
          ),
        ])}
      />
    </Stack>
  );
}

export default function BlogRoom() {
  const now = useNow();
  const [marks, setMarks] = useCanvasState<Marks>("needsYou", {});
  const [shareMarks, setShareMarks] = useCanvasState<ShareMarks>("shares", {});
  const [selected, setSelected] = useCanvasState<Tab>("tab", "Overview");
  const shown: Record<Tab, boolean> = {
    Overview: true,
    Posts: room.posts.length > 0,
    Pipeline: room.pipeline.length > 0,
    Posted: room.posted.length > 0,
    Log: room.log.length > 0,
    Decisions: room.decisions.length > 0,
  };
  const tabs = TABS.filter((tab) => shown[tab]);
  const tab: Tab = shown[selected] ? selected : "Overview";
  const states = room.posts.map((post) => post.shares.map((share) => shareState(share, shareMarks)));
  const toAnnounce = states.filter((post) => post.length > 0 && post.every((state) => state === "draft")).length;
  const toConfirm = states.flat().filter((state) => state === "unconfirmed").length;
  const open = room.needsYou.filter((item) => !settled(item, marks, shareMarks)).length;
  return (
    <Stack gap={18} style={{ padding: 4 }}>
      <Stack gap={6}>
        <H1>Blog room</H1>
        <Text>{room.summary}</Text>
        <Text size="small" tone="tertiary">
          {`Updated ${ago(room.updated, now)} (${when(room.updated)})`}
        </Text>
      </Stack>

      <Row gap={32} wrap>
        <Stat value={`${room.posts.length}`} label="Posts live" />
        <Stat value={`${toAnnounce}`} label="Ready to announce" tone={toAnnounce > 0 ? "warning" : undefined} />
        <Stat value={`${toConfirm}`} label="Not confirmed" />
        <Stat value={`${room.pipeline.length}`} label="In the pipeline" />
        <Stat value={`${open}`} label="Waiting on you" />
      </Row>

      <Row gap={6} wrap>
        {tabs.map((name) => (
          <span key={name}>
            <Pill active={tab === name} onClick={() => setSelected(name)}>
              {name === "Log" ? `Log · ${room.log.length}` : name === "Pipeline" ? `Pipeline · ${room.pipeline.length}` : name}
            </Pill>
          </span>
        ))}
      </Row>
      <Divider />

      {tab === "Overview" && (
        <OverviewTab now={now} marks={marks} setMarks={setMarks} shareMarks={shareMarks} setShareMarks={setShareMarks} />
      )}
      {tab === "Posts" && <PostsTab marks={shareMarks} setMarks={setShareMarks} />}
      {tab === "Pipeline" && <PipelineTab />}
      {tab === "Posted" && <PostedTab />}
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
