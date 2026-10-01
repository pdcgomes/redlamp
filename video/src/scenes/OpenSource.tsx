import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Caption } from "../components/Caption";
import { Lens } from "../components/Lens";
import { Stage } from "../components/Stage";
import { appear, useLayout } from "../layout";
import { color, font } from "../theme";

const repo = "github.com/pdcgomes/redlamp";

function Device({ kind, lit, t }: { kind: "mac" | "ipad" | "iphone"; lit: boolean; t: number }) {
  const size = { mac: [360, 236], ipad: [180, 240], iphone: [104, 210] }[kind];
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 14, opacity: t, transform: `translateY(${(1 - t) * 24}px)` }}>
      <div
        style={{
          width: size[0],
          height: size[1],
          borderRadius: kind === "mac" ? 18 : kind === "ipad" ? 22 : 26,
          border: `3px solid ${lit ? color.ring : color.dim}`,
          background: lit ? "radial-gradient(70% 70% at 50% 45%, rgba(224,64,46,0.35), rgba(10,7,7,0.9))" : "rgba(243,238,232,0.03)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        {lit ? <Lens size={120} glow={1} /> : null}
      </div>
      <span style={{ fontFamily: font.family, fontSize: 20, color: lit ? color.paper : color.dim }}>
        {kind === "mac" ? "Mac · first" : kind === "ipad" ? "iPad · later" : "iPhone · later"}
      </span>
    </div>
  );
}

/** The licence lands like a stamp; the repository types itself out; Mac first, iPad and iPhone after. */
export function OpenSource({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const layout = useLayout();
  const stamp = spring({ frame: frame - 24, fps, config: { damping: 10, stiffness: 140 } });
  const typed = Math.floor(interpolate(frame, [60, 110], [0, repo.length], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }));

  return (
    <Stage glowX={0.5} glowY={0.2}>
      <AbsoluteFill
        style={{
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: layout.wide ? 54 : 64,
          padding: layout.wide ? "0 100px" : "140px 60px 90px",
        }}
      >
        <Caption
          title="Free and open source."
          sub="Mac first, then iPad and iPhone from the same engine."
          start={4}
          end={dur - 16}
          align="center"
          size={layout.wide ? 64 : 66}
        />
        <div style={{ display: "flex", alignItems: "center", gap: 28, flexDirection: layout.wide ? "row" : "column" }}>
          <div
            style={{
              display: "flex",
              overflow: "hidden",
              borderRadius: 14,
              border: `1px solid ${color.hairline}`,
              fontFamily: font.family,
              fontSize: 34,
              fontWeight: 600,
              transform: `scale(${1.5 - 0.5 * stamp}) rotate(${-4 + 2 * stamp}deg)`,
              opacity: Math.min(1, stamp * 1.5),
            }}
          >
            <span style={{ background: "rgba(87,80,78,0.6)", color: color.ring, padding: "14px 20px" }}>license</span>
            <span style={{ background: color.paper, color: "#1a1414", padding: "14px 22px" }}>MPL-2.0</span>
          </div>
          <div style={{ fontFamily: font.mono, fontSize: 32, color: color.ring, minWidth: 560, opacity: appear(frame, 56, 10) }}>
            {repo.slice(0, typed)}
            <span style={{ opacity: frame % 30 < 15 ? 1 : 0, color: color.filament }}>▍</span>
          </div>
        </div>
        <div style={{ display: "flex", alignItems: "flex-end", gap: layout.wide ? 60 : 34 }}>
          <Device kind="mac" lit t={appear(frame, 118, 26)} />
          <Device kind="ipad" lit={false} t={appear(frame, 138, 26)} />
          <Device kind="iphone" lit={false} t={appear(frame, 152, 26)} />
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
