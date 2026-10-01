import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Caption } from "../components/Caption";
import { FilmIcon, type Look, Photo } from "../components/Media";
import { Stage } from "../components/Stage";
import { useLayout } from "../layout";
import { color, font } from "../theme";

const looks: { look: Look; name: string; kind: string; icon?: string }[] = [
  { look: "original", name: "Redlamp Color", kind: "Redlamp's own rendering" },
  { look: "portra-400", name: "Portra 400", kind: "Colour negative · Frontier-like scan", icon: "portra-400" },
  { look: "velvia-50", name: "Velvia 50", kind: "Slide film on a light box", icon: "velvia-50" },
  { look: "cinestill-800t", name: "CineStill 800T", kind: "Tungsten negative · halation", icon: "cinestill-800t" },
  { look: "vision3-500t-2383", name: "Vision3 500T · 2383", kind: "Cinema negative, printed and projected", icon: "vision3-500t-2383" },
  { look: "tri-x-400", name: "Tri-X 400", kind: "Black and white negative", icon: "tri-x-400" },
];

const reel = ["portra-400", "ektar-100", "gold-200", "superia-400", "cinestill-800t", "vision3-500t-2383", "provia-100f", "velvia-50", "tri-x-400", "hp5-plus", "tri-x-multigrade"];

/** Eleven canisters roll in; the photo cycles through the stocks, each built from its datasheet. */
export function Film({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const layout = useLayout();
  const start = 60;
  const per = Math.floor((dur - start - 20) / looks.length);
  const index = Math.min(looks.length - 1, Math.max(0, Math.floor((frame - start) / per)));
  const w = layout.wide ? 1000 : 940;
  const h = w * (layout.tall ? 1.15 : 0.62);
  const iconSize = layout.wide ? 84 : 72;

  return (
    <Stage glowX={0.5} glowY={0.08}>
      <AbsoluteFill
        style={{
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: layout.wide ? 36 : 48,
          padding: layout.wide ? "30px 100px 0" : "130px 60px 80px",
        }}
      >
        <Caption
          title="Eleven film stocks, simulated from their datasheets."
          start={4}
          end={dur - 16}
          align="center"
          size={layout.wide ? 54 : 62}
          style={{ maxWidth: layout.wide ? 1400 : 920 }}
        />
        <div style={{ position: "relative", width: w, height: h, borderRadius: 16, overflow: "hidden", boxShadow: "0 30px 80px rgba(0,0,0,0.6)" }}>
          {looks.map((item, i) => {
            const t0 = start + i * per;
            const opacity = i === 0 ? 1 : interpolate(frame, [t0, t0 + 12], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
            return (
              <AbsoluteFill key={item.look} style={{ opacity }}>
                <Photo look={item.look} />
              </AbsoluteFill>
            );
          })}
          <div
            style={{
              position: "absolute",
              left: 24,
              bottom: 24,
              display: "flex",
              alignItems: "center",
              gap: 14,
              padding: "12px 20px 12px 14px",
              borderRadius: 16,
              background: "rgba(14,10,10,0.72)",
              border: `1px solid ${color.hairline}`,
              fontFamily: font.family,
            }}
          >
            {looks[index].icon ? <FilmIcon id={looks[index].icon} size={52} /> : <div style={{ width: 8 }} />}
            <div>
              <div style={{ fontSize: 26, fontWeight: 600, color: color.paper }}>{looks[index].name}</div>
              <div style={{ fontSize: 17, color: color.mute }}>{looks[index].kind}</div>
            </div>
          </div>
        </div>
        <div style={{ display: "flex", gap: layout.wide ? 18 : 10, flexWrap: "wrap", justifyContent: "center", maxWidth: layout.wide ? 1300 : 940 }}>
          {reel.map((id, i) => {
            const roll = spring({ frame: frame - 6 - i * 3, fps, config: { damping: 16, stiffness: 110 } });
            const lit = looks[index].icon === id;
            return (
              <div
                key={id}
                style={{
                  transform: `translateX(${(1 - roll) * 500}px) rotate(${(1 - roll) * 220}deg) translateY(${lit ? -10 : 0}px)`,
                  opacity: (lit ? 1 : 0.55) * roll,
                }}
              >
                <FilmIcon id={id} size={iconSize} />
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
