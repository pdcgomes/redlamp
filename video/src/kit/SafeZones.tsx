import { AbsoluteFill, useVideoConfig } from "remotion";

/**
 * Where the apps lay their own interface over a vertical video, at 1080 × 1920: the status bar
 * and tabs at the top, the caption, account and sound at the bottom, and the like, comment and
 * share buttons down the right. Conservative across TikTok, Instagram Reels and YouTube Shorts;
 * anything that must be read stays outside them. Square and feed shapes keep a plain margin.
 */
export const safeZones = {
  tall: { top: 260, bottom: 480, right: 160, rightFrom: 700, rightTo: 1600, left: 60 },
  feed: { margin: 60 },
};

/** The zones drawn over the frame, for review in Studio: never rendered into a cut. */
export function SafeZones() {
  const { width, height } = useVideoConfig();
  const fill = "rgba(80,160,255,0.22)";
  const edge = "1px dashed rgba(120,190,255,0.9)";
  const label = { position: "absolute" as const, font: "500 22px Inter, sans-serif", color: "rgba(190,220,255,0.95)", padding: 10 };
  if (height / width > 1.5) {
    const z = safeZones.tall;
    const s = height / 1920;
    return (
      <AbsoluteFill style={{ pointerEvents: "none" }}>
        <div style={{ position: "absolute", left: 0, right: 0, top: 0, height: z.top * s, background: fill, borderBottom: edge }}>
          <span style={label}>Status bar and tabs</span>
        </div>
        <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: z.bottom * s, background: fill, borderTop: edge }}>
          <span style={label}>Caption, account and sound</span>
        </div>
        <div
          style={{
            position: "absolute",
            right: 0,
            width: z.right * s,
            top: z.rightFrom * s,
            height: (z.rightTo - z.rightFrom) * s,
            background: fill,
            borderLeft: edge,
          }}
        >
          <span style={{ ...label, writingMode: "vertical-rl" }}>Like, comment, share</span>
        </div>
        <div style={{ position: "absolute", left: 0, width: z.left * s, top: z.top * s, bottom: z.bottom * s, borderRight: edge }} />
      </AbsoluteFill>
    );
  }
  const m = safeZones.feed.margin * (width / 1080);
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      <div style={{ position: "absolute", inset: m, border: edge }}>
        <span style={label}>Margin</span>
      </div>
    </AbsoluteFill>
  );
}
