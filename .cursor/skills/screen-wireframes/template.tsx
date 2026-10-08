import { Callout, Divider, Grid, H1, H2, H3, Pill, Row, Stack, Table, Text, useCanvasState, useHostTheme } from "cursor/canvas";
import type { Color, CSSProperties, TextProps } from "cursor/canvas";

type Node = TextProps["children"];

// ---------------------------------------------------------------- what the canvas shows: replace these

const WIREFRAMES = {
  title: "The Import window: wireframes",
  intro:
    "How the Import window looks and works, from what's built on library/catalog and what the design and the tracker plan for 1.0. 7 October 2026.",
  reading:
    "Boxes are regions, numbers point to the notes under each wireframe, and counts are made up. Every region says where it stands:",
};

type Status = "built" | "doing" | "planned" | "later";

/** The four states every region, step and note is marked with; reword the meanings for the project. */
const STATUS: Record<Status, { label: string; color: Color; meaning: string }> = {
  built: { label: "Built", color: "green", meaning: "Merged and tested; it shows in the app." },
  doing: { label: "Being built", color: "blue", meaning: "An agent is building it now." },
  planned: { label: "Planned", color: "gray", meaning: "In the tracker for this release; its engine may exist without its panel." },
  later: { label: "Later, or waits on you", color: "purple", meaning: "After this release, or waiting on a measurement or a decision of yours." },
};

/** The user's path through the screen, three to six steps, each with where it stands. */
const FLOW: { title: string; text: string; status: Status }[] = [
  { title: "Insert a card", text: "The window opens on it, its photos browsed from their embedded previews before anything is copied.", status: "built" },
  { title: "Cull before copying", text: "Choose, rate and flag with Library's keys; photos already in the library are left out and counted.", status: "built" },
  { title: "Say where they go", text: "A destination, folder and name templates with a live example, and a backup that's a real copy.", status: "built" },
  { title: "Import and erase", text: "One journaled copy off the main thread; each card says when it's safe to erase, with Eject.", status: "doing" },
];

/** What makes the design work, three to six, each a short title and a sentence. */
const PRINCIPLES: [string, string][] = [
  ["Nothing waits on the card", "Previews come from the files' embedded JPEGs, newest first, so culling starts before copying does."],
  ["One journal", "A forced quit resumes the import where it stopped; nothing is half copied."],
  ["The same keys as Library", "Ratings, flags and labels work in the window as they do in the grid."],
];

/** The choices the wireframes leave open: only those whose answer changes what's built next. */
type Question = { title: string; now: string; options: string[]; lean: string; answer?: string };

const QUESTIONS: Question[] = [
  {
    title: "Does the window open when a card is inserted?",
    now: "It does, as Lightroom Classic does, with a setting to turn it off.",
    options: ["Open it, as now", "Show a notification first, opening the window from it"],
    lean: "Open it: a card goes in to be imported, and the setting is one click away.",
  },
];

// ---------------------------------------------------------------- building blocks: keep

const MONO = "ui-monospace, SFMono-Regular, Menlo, monospace";

function Dot({ color, size = 8 }: { color: string; size?: number }) {
  return (
    <span
      style={{ display: "inline-block", width: size, height: size, borderRadius: size / 2, background: color, flexShrink: 0 }}
    />
  );
}

function StatusTag({ status }: { status: Status }) {
  const theme = useHostTheme();
  const s = STATUS[status];
  return (
    <span
      style={{ display: "inline-flex", alignItems: "center", gap: 5, fontSize: 11, color: theme.text.secondary, whiteSpace: "nowrap" }}
    >
      <Dot color={theme.category[s.color]} size={7} />
      {s.label}
    </span>
  );
}

/** The number a region carries, and its note under the wireframe. */
function Marker({ n }: { n: number }) {
  const theme = useHostTheme();
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: 16,
        height: 16,
        borderRadius: 8,
        background: theme.accent.primary,
        color: theme.text.onAccent,
        fontSize: 10,
        fontWeight: 600,
        flexShrink: 0,
      }}
    >
      {n}
    </span>
  );
}

function Caption({ children, style }: { children: string; style?: CSSProperties }) {
  const theme = useHostTheme();
  return (
    <span
      style={{
        fontSize: 9.5,
        fontWeight: 600,
        letterSpacing: 0.5,
        textTransform: "uppercase",
        color: theme.text.tertiary,
        whiteSpace: "nowrap",
        ...style,
      }}
    >
      {children}
    </span>
  );
}

/** A region of a wireframe: numbered, labelled and marked with where it stands. Dashed for what shows on demand. */
function Box({
  n,
  label,
  status,
  children,
  style,
  dashed,
}: {
  n?: number;
  label?: string;
  status?: Status;
  children?: Node;
  style?: CSSProperties;
  dashed?: boolean;
}) {
  const theme = useHostTheme();
  return (
    <div
      style={{
        border: `1px ${dashed ? "dashed" : "solid"} ${theme.stroke.secondary}`,
        borderRadius: 6,
        padding: 7,
        minWidth: 0,
        ...style,
      }}
    >
      {n !== undefined || label || status ? (
        <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 6 }}>
          {n !== undefined ? <Marker n={n} /> : null}
          {label ? <Caption>{label}</Caption> : null}
          {status ? (
            <span style={{ marginLeft: "auto" }}>
              <StatusTag status={status} />
            </span>
          ) : null}
        </div>
      ) : null}
      {children}
    </div>
  );
}

function Kbd({ children }: { children: string }) {
  const theme = useHostTheme();
  return (
    <span
      style={{
        display: "inline-block",
        minWidth: 16,
        padding: "0 4px",
        border: `1px solid ${theme.stroke.secondary}`,
        borderRadius: 4,
        fontSize: 10.5,
        lineHeight: "16px",
        textAlign: "center",
        color: theme.text.primary,
        fontFamily: MONO,
      }}
    >
      {children}
    </span>
  );
}

function Chip({ children, dim }: { children: Node; dim?: boolean }) {
  const theme = useHostTheme();
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 4,
        padding: "1px 7px",
        borderRadius: 10,
        fontSize: 11,
        background: theme.fill.secondary,
        color: dim ? theme.text.tertiary : theme.text.primary,
        whiteSpace: "nowrap",
      }}
    >
      {children}
    </span>
  );
}

function Mini({ children, tone = "secondary", style }: { children: Node; tone?: "primary" | "secondary" | "tertiary"; style?: CSSProperties }) {
  const theme = useHostTheme();
  return <span style={{ fontSize: 11, color: theme.text[tone], ...style }}>{children}</span>;
}

/** A placeholder for a cell of content (a photo, a document, a card), with an optional caption and badge. */
function Tile({ w = 62, h, caption, badge, selected, dim }: { w?: number; h?: number; caption?: string; badge?: string; selected?: boolean; dim?: boolean }) {
  const theme = useHostTheme();
  return (
    <span style={{ display: "inline-flex", flexDirection: "column", gap: 3, width: w }}>
      <span
        style={{
          position: "relative",
          width: w,
          height: h ?? Math.round(w * 0.7),
          borderRadius: 3,
          background: dim ? theme.fill.quaternary : theme.fill.secondary,
          outline: selected ? `2px solid ${theme.accent.primary}` : undefined,
          outlineOffset: 1,
        }}
      >
        {badge ? (
          <span style={{ position: "absolute", right: 3, bottom: 2, fontSize: 9, color: theme.text.secondary }}>{badge}</span>
        ) : null}
      </span>
      {caption ? (
        <span style={{ fontSize: 9.5, color: theme.text.tertiary, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {caption}
        </span>
      ) : null}
    </span>
  );
}

type ListItem = { label: string; count?: string; depth?: number; selected?: boolean; dim?: boolean };

/** A sidebar's section: a title and rows with counts, nested by depth. */
function ListSection({ title, status, items, note }: { title?: string; status?: Status; items: ListItem[]; note?: string }) {
  const theme = useHostTheme();
  return (
    <div style={{ minWidth: 0 }}>
      {title || status ? (
        <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "2px 5px 4px" }}>
          {title ? <Caption>{title}</Caption> : null}
          {status ? (
            <span style={{ marginLeft: "auto" }}>
              <StatusTag status={status} />
            </span>
          ) : null}
        </div>
      ) : null}
      {items.map((item) => (
        <div
          key={`${item.label}-${item.depth ?? 0}`}
          style={{
            display: "flex",
            alignItems: "center",
            gap: 6,
            fontSize: 11.5,
            padding: `2px 5px 2px ${5 + (item.depth ?? 0) * 12}px`,
            borderRadius: 4,
            background: item.selected ? theme.fill.secondary : undefined,
            color: item.dim ? theme.text.tertiary : theme.text.primary,
          }}
        >
          <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.label}</span>
          {item.count ? <span style={{ marginLeft: "auto", color: theme.text.tertiary, fontSize: 10.5 }}>{item.count}</span> : null}
        </div>
      ))}
      {note ? <div style={{ fontSize: 10, color: theme.text.tertiary, padding: "2px 5px" }}>{note}</div> : null}
    </div>
  );
}

type Note = { n: number; title: string; text: string; status: Status };

/** The notes under a wireframe, one per numbered region. */
function Notes({ items, columns = 2 }: { items: Note[]; columns?: number }) {
  return (
    <Grid columns={columns} gap={14}>
      {items.map((item) => (
        <div key={item.n} style={{ display: "grid", gridTemplateColumns: "18px minmax(0, 1fr)", gap: 8 }}>
          <Marker n={item.n} />
          <Stack gap={2}>
            <Row gap={8} align="center" wrap>
              <Text size="small" weight="semibold">
                {item.title}
              </Text>
              <StatusTag status={item.status} />
            </Row>
            <Text size="small" tone="secondary">
              {item.text}
            </Text>
          </Stack>
        </div>
      ))}
    </Grid>
  );
}

/** A window's frame with its toolbar. */
function Window({ toolbar, children }: { toolbar?: Node; children: Node }) {
  const theme = useHostTheme();
  return (
    <div style={{ border: `1px solid ${theme.stroke.primary}`, borderRadius: 10, overflow: "hidden", background: theme.bg.editor }}>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          height: 34,
          padding: "0 10px",
          background: theme.bg.chrome,
          borderBottom: `1px solid ${theme.stroke.tertiary}`,
        }}
      >
        <span style={{ display: "flex", gap: 5 }}>
          {[0, 1, 2].map((i) => (
            <Dot key={i} color={theme.fill.primary} size={10} />
          ))}
        </span>
        {toolbar}
      </div>
      {children}
    </div>
  );
}

function Segmented({ items, active }: { items: string[]; active: string }) {
  const theme = useHostTheme();
  return (
    <span style={{ display: "inline-flex", border: `1px solid ${theme.stroke.secondary}`, borderRadius: 5, overflow: "hidden" }}>
      {items.map((item) => (
        <span
          key={item}
          style={{
            fontSize: 11,
            padding: "2px 9px",
            background: item === active ? theme.fill.secondary : undefined,
            color: item === active ? theme.text.primary : theme.text.secondary,
          }}
        >
          {item}
        </span>
      ))}
    </span>
  );
}

/** A labelled value, as an inspector's or a form's rows are spaced. */
function Field({ name, value, tone, wrap }: { name: string; value: string; tone?: "secondary" | "tertiary"; wrap?: boolean }) {
  const theme = useHostTheme();
  return (
    <div style={{ display: "grid", gridTemplateColumns: "62px minmax(0, 1fr)", gap: 6, fontSize: 11, padding: "1px 0" }}>
      <span style={{ color: theme.text.tertiary, textAlign: "right" }}>{name}</span>
      <span
        style={{
          color: tone === "tertiary" ? theme.text.tertiary : theme.text.primary,
          overflow: "hidden",
          textOverflow: wrap ? undefined : "ellipsis",
          whiteSpace: wrap ? "normal" : "nowrap",
          wordBreak: wrap ? "break-all" : undefined,
          fontFamily: wrap ? MONO : undefined,
        }}
      >
        {value}
      </span>
    </div>
  );
}

function Slider({ left, right, at = 0.5, width = 90 }: { left?: string; right?: string; at?: number; width?: number }) {
  const theme = useHostTheme();
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
      {left ? <Mini tone="tertiary">{left}</Mini> : null}
      <span style={{ position: "relative", width, height: 3, borderRadius: 2, background: theme.fill.secondary }}>
        <span
          style={{
            position: "absolute",
            left: `calc(${at * 100}% - 5px)`,
            top: -4,
            width: 10,
            height: 10,
            borderRadius: 5,
            background: theme.text.secondary,
          }}
        />
      </span>
      {right ? <Mini tone="tertiary">{right}</Mini> : null}
    </span>
  );
}

function Legend() {
  return (
    <Row gap={16} wrap>
      {(Object.keys(STATUS) as Status[]).map((s) => (
        <span key={s}>
          <StatusTag status={s} />
        </span>
      ))}
    </Row>
  );
}

// ---------------------------------------------------------------- overview and questions: keep

function OverviewTab() {
  const theme = useHostTheme();
  const open = QUESTIONS.filter((q) => !q.answer).length;
  return (
    <Stack gap={22}>
      <Grid columns={FLOW.length} gap={10}>
        {FLOW.map((f, i) => (
          <div
            key={f.title}
            style={{
              border: `1px solid ${theme.stroke.secondary}`,
              borderRadius: 8,
              padding: 12,
              display: "flex",
              flexDirection: "column",
              gap: 6,
              minWidth: 0,
            }}
          >
            <Row gap={6} align="center">
              <Marker n={i + 1} />
              <Text size="small" weight="semibold">
                {f.title}
              </Text>
            </Row>
            <Text size="small" tone="secondary">
              {f.text}
            </Text>
            <span style={{ marginTop: "auto" }}>
              <StatusTag status={f.status} />
            </span>
          </div>
        ))}
      </Grid>
      <Grid columns="minmax(0, 1.2fr) minmax(0, 1fr)" gap={24} align="start">
        <Stack gap={10}>
          <H3>What makes it work</H3>
          <Stack gap={8}>
            {PRINCIPLES.map(([title, text]) => (
              <div key={title} style={{ display: "grid", gridTemplateColumns: "10px minmax(0, 1fr)", gap: 8 }}>
                <span style={{ paddingTop: 6 }}>
                  <Dot color={theme.text.tertiary} size={4} />
                </span>
                <Text size="small">
                  <span style={{ fontWeight: 600 }}>{title}. </span>
                  <span style={{ color: theme.text.secondary }}>{text}</span>
                </Text>
              </div>
            ))}
          </Stack>
        </Stack>
        <Stack gap={10}>
          <H3>Reading these wireframes</H3>
          <Text size="small" tone="secondary">
            {WIREFRAMES.reading}
          </Text>
          <Stack gap={6}>
            {(Object.keys(STATUS) as Status[]).map((s) => (
              <div key={s} style={{ display: "grid", gridTemplateColumns: "150px minmax(0, 1fr)", gap: 8 }}>
                <StatusTag status={s} />
                <Text size="small" tone="secondary">
                  {STATUS[s].meaning}
                </Text>
              </div>
            ))}
          </Stack>
          {open > 0 ? (
            <Callout tone="neutral" title={open === 1 ? "A question for you" : `${open} questions for you`}>
              The Questions tab lists the choices these wireframes leave open. Your answers decide how the parts still to
              come are built.
            </Callout>
          ) : null}
        </Stack>
      </Grid>
    </Stack>
  );
}

function QuestionsTab() {
  const theme = useHostTheme();
  const open = QUESTIONS.filter((q) => !q.answer);
  const answered = QUESTIONS.filter((q) => q.answer);
  return (
    <Stack gap={18}>
      {open.length > 0 ? (
        <Stack gap={6}>
          <H2>What these wireframes leave for you</H2>
          <Text tone="secondary">
            Each changes parts that aren't built yet, or a default. Say which you'd like, or anything you'd change on the
            other tabs.
          </Text>
        </Stack>
      ) : null}
      {open.map((q, i) => (
        <div
          key={q.title}
          style={{
            display: "grid",
            gridTemplateColumns: "18px minmax(0, 1fr)",
            gap: 10,
            paddingBottom: 14,
            borderBottom: `1px solid ${theme.stroke.tertiary}`,
          }}
        >
          <Marker n={i + 1} />
          <Stack gap={6}>
            <Text weight="semibold">{q.title}</Text>
            <Text size="small" tone="secondary">
              {q.now}
            </Text>
            <Stack gap={3}>
              {q.options.map((o, j) => (
                <Text key={o} size="small">
                  <span style={{ color: theme.text.tertiary }}>{`${String.fromCharCode(65 + j)}. `}</span>
                  {o}
                </Text>
              ))}
            </Stack>
            <Text size="small" tone="tertiary">
              {`My lean: ${q.lean}`}
            </Text>
          </Stack>
        </div>
      ))}
      {answered.length > 0 ? (
        <Stack gap={8}>
          <H3>Answered</H3>
          {answered.map((q) => (
            <Text key={q.title} size="small">
              <span style={{ fontWeight: 600 }}>{q.title} </span>
              <span style={{ color: theme.text.secondary }}>{q.answer}</span>
            </Text>
          ))}
        </Stack>
      ) : null}
    </Stack>
  );
}

// ---------------------------------------------------------------- one tab per area of the screen: replace this example

const EXAMPLE_NOTES: Note[] = [
  { n: 1, title: "Sources", text: "Cards as they're inserted and any folder added, each with its count; photos already imported are counted apart.", status: "built" },
  { n: 2, title: "The photos", text: "Newest first from their embedded previews, chosen, rated and flagged with Library's keys before copying.", status: "built" },
  { n: 3, title: "Where they go", text: "Destination, folder and name templates with a live example from the first chosen photo, a backup and raw-only.", status: "built" },
  { n: 4, title: "Metadata presets", text: "A preset's ticked fields applied at the destination (LIB-22); a disabled place in the window today.", status: "planned" },
];

function ExampleTab() {
  return (
    <Stack gap={18}>
      <Stack gap={6}>
        <H2>The window</H2>
        <Text tone="secondary">One window of three columns, as the import begins.</Text>
      </Stack>
      <Window toolbar={<Segmented items={["All", "Chosen", "Left out"]} active="All" />}>
        <div style={{ display: "grid", gridTemplateColumns: "170px minmax(0, 1fr) 230px", gap: 10, padding: 10 }}>
          <Box n={1} label="From" status="built">
            <ListSection
              items={[
                { label: "EOS R5 card", count: "1,204", selected: true },
                { label: "Already in the library", count: "312", depth: 1, dim: true },
                { label: "Z 6 card", count: "640" },
              ]}
            />
          </Box>
          <Box n={2} label="Photos" status="built">
            <Row gap={6} wrap>
              {Array.from({ length: 12 }, (_, i) => (
                <span key={i}>
                  <Tile w={54} selected={i < 2} badge={i === 3 ? "★4" : undefined} />
                </span>
              ))}
            </Row>
            <Mini tone="tertiary" style={{ display: "block", marginTop: 6 }}>
              892 to import · the 312 already imported are left out
            </Mini>
          </Box>
          <Stack gap={8}>
            <Box n={3} label="To" status="built">
              <Field name="To" value="T7 Shield › Photos" />
              <Field name="Folders" value="{date:yyyy}/{date:yyyy-MM-dd}" wrap />
              <Field name="Example" value="2026/2026-10-06/IMG_0001.CR3" tone="tertiary" wrap />
              <Row gap={6} align="center" style={{ marginTop: 6 }}>
                <Chip>Import 892</Chip>
                <Kbd>⏎</Kbd>
              </Row>
            </Box>
            <Box n={4} label="Preset" status="planned" dashed>
              <Field name="Preset" value="Client day" tone="tertiary" />
            </Box>
          </Stack>
        </div>
      </Window>
      <Notes items={EXAMPLE_NOTES} />
      <Stack gap={8}>
        <H3>Keys</H3>
        <Table
          headers={["Keys", "What it does", "Status"]}
          rows={[
            ["0 to 5, P, X, U", "Rate and flag the chosen photos before copying", STATUS.built.label],
            ["⌘A", "Choose every photo of the source", STATUS.built.label],
          ]}
        />
      </Stack>
    </Stack>
  );
}

// ---------------------------------------------------------------- the canvas: list the area tabs between Overview and Questions

const TABS = ["Overview", "The window", "Questions"] as const;
type Tab = (typeof TABS)[number];

export default function Wireframes() {
  const [tab, setTab] = useCanvasState<Tab>("tab", "Overview");
  return (
    <Stack gap={18} style={{ padding: 4 }}>
      <Stack gap={6}>
        <H1>{WIREFRAMES.title}</H1>
        <Text tone="secondary">{WIREFRAMES.intro}</Text>
        <Legend />
      </Stack>
      <Row gap={6} wrap>
        {TABS.map((name) => (
          <span key={name}>
            <Pill active={tab === name} onClick={() => setTab(name)}>
              {name}
            </Pill>
          </span>
        ))}
      </Row>
      <Divider />
      {tab === "Overview" && <OverviewTab />}
      {tab === "The window" && <ExampleTab />}
      {tab === "Questions" && <QuestionsTab />}
    </Stack>
  );
}
