import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Caption } from "../components/Caption";
import { glass, Photo } from "../components/Media";
import { Stage } from "../components/Stage";
import { useLayout } from "../layout";
import { color, font } from "../theme";

const edits = ["exposure: +0.45", "highlights: −40", "shadows: +35", "vibrance: +20", "look: Portra 400"];

/** The raw file locks shut; a small sidecar slides out beside it and the edits are written there. */
export function Original({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const layout = useLayout();
  const lock = spring({ frame: frame - 40, fps, config: { damping: 9, stiffness: 180 } });
  const slide = spring({ frame: frame - 70, fps, config: { damping: 18, stiffness: 90 } });
  const typed = interpolate(frame, [95, 200], [0, edits.join("\n").length], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const text = edits.join("\n").slice(0, Math.floor(typed));

  const raw = (
    <div style={{ ...glass, width: 480, padding: 22, fontFamily: font.family, position: "relative" }}>
      <div style={{ borderRadius: 12, overflow: "hidden", height: 300 }}>
        <Photo />
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 18 }}>
        <div>
          <div style={{ fontSize: 24, fontWeight: 600, color: color.paper }}>DSC_0750.NEF</div>
          <div style={{ fontSize: 17, color: color.dim, marginTop: 4 }}>Nikon raw · 25.6 MB · never changes</div>
        </div>
        <svg width="56" height="64" viewBox="0 0 28 32">
          <path
            d={`M 7 14 V 9 A 7 7 0 0 1 21 9 V ${14 - (1 - lock) * 5}`}
            fill="none"
            stroke={color.ring}
            strokeWidth="3"
            strokeLinecap="round"
            transform={`translate(0 ${-(1 - lock) * 3})`}
          />
          <rect x="3" y="14" width="22" height="16" rx="4" fill={color.steel} />
          <circle cx="14" cy="22" r="2.4" fill={color.wall} />
        </svg>
      </div>
    </div>
  );

  const sidecar = (
    <div
      style={{
        ...glass,
        width: 380,
        padding: "22px 24px",
        fontFamily: font.family,
        opacity: slide,
        transform: layout.wide ? `translateX(${(slide - 1) * 160}px)` : `translateY(${(slide - 1) * 120}px)`,
      }}
    >
      <div style={{ fontSize: 22, fontWeight: 600, color: color.paper }}>DSC_0750.NEF.redlamp</div>
      <div style={{ fontSize: 16, color: color.dim, marginTop: 4 }}>Sidecar · 2 KB</div>
      <pre
        style={{
          fontFamily: font.mono,
          fontSize: 20,
          lineHeight: 1.7,
          color: color.ring,
          margin: "16px 0 0",
          minHeight: 5 * 34,
          whiteSpace: "pre-wrap",
        }}
      >
        {text}
        <span style={{ opacity: frame % 30 < 15 ? 1 : 0, color: color.filament }}>▍</span>
      </pre>
    </div>
  );

  return (
    <Stage glowX={0.5} glowY={0.15}>
      <AbsoluteFill
        style={{
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: layout.wide ? 70 : 56,
          padding: layout.wide ? "0 100px" : "140px 60px 90px",
        }}
      >
        <Caption
          title="Your originals are never touched."
          sub="Every edit lives in a small sidecar file next to the photo."
          start={6}
          end={dur - 16}
          align="center"
          size={layout.wide ? 62 : 64}
        />
        <div style={{ display: "flex", flexDirection: layout.wide ? "row" : "column", alignItems: "center", gap: 36 }}>
          {raw}
          {sidecar}
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
