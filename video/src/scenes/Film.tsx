import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Words } from "../components/Kinetic";
import { Landscape } from "../components/Landscape";
import { FilmIcon } from "../components/Media";
import { Stage } from "../components/Stage";
import { type LookId, looks } from "../grade";
import { useLayout, useSprings } from "../layout";
import { color, font } from "../theme";

const sequence: LookId[] = [
  "portra-400",
  "ektar-100",
  "cinestill-800t",
  "vision3-500t-2383",
  "vision3-2383-bleach-bypass",
  "velvia-50",
  "velvia-50-cross",
  "tri-x-400",
];

/** Every look in the README's film table, in its order. */
const all = [
  "portra-400",
  "ektar-100",
  "gold-200",
  "superia-400",
  "portra-400-overexposed",
  "cinestill-800t",
  "vision3-500t-2383",
  "vision3-2383-bleach-bypass",
  "provia-100f",
  "velvia-50",
  "velvia-50-cross",
  "provia-100f-cross",
  "tri-x-400",
  "tri-x-1600",
  "hp5-plus",
  "tri-x-multigrade",
  "tri-x-multigrade-soft",
  "tri-x-multigrade-hard",
];

const FIRST = 4;
const PER = 9;
const GRID = FIRST + sequence.length * PER + 4;

/** Hard cuts through eight looks on the beat, then all eighteen land in a grid. */
export function Film() {
  const frame = useCurrentFrame();
  const s = useSprings();
  const layout = useLayout();
  const index = Math.min(sequence.length - 1, Math.max(0, Math.floor((frame - FIRST) / PER)));
  const cutAt = FIRST + index * PER;
  const look = looks[sequence[index]];
  const box = layout.wide ? { w: 1240, h: 660 } : layout.tall ? { w: 980, h: 1240 } : { w: 940, h: 720 };
  const enter = s(0, "pop");
  const punch = 1.045 - 0.045 * s(cutAt, "pop");
  const label = s(cutAt, "pop");
  const leave = s(GRID, "snap");
  const cols = layout.wide ? 9 : 6;
  const icon = layout.wide ? 132 : layout.tall ? 138 : 128;

  return (
    <Stage glowY={0.1} pulses={sequence.map((_, i) => FIRST + i * PER)}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: 1 - leave, transform: `scale(${1 - 0.15 * leave})` }}>
        <div
          style={{
            position: "relative",
            width: box.w,
            height: box.h,
            borderRadius: 22,
            overflow: "hidden",
            boxShadow: "0 30px 80px rgba(0,0,0,0.6)",
            transform: `translateY(${(1 - enter) * 220}px) scale(${(0.9 + 0.1 * enter) * punch})`,
          }}
        >
          <Landscape grade={frame < FIRST ? {} : look.grade} />
          <div
            style={{
              position: "absolute",
              left: 28,
              bottom: 28,
              display: "flex",
              alignItems: "center",
              gap: 18,
              padding: "14px 26px 14px 16px",
              borderRadius: 20,
              background: "rgba(14,10,10,0.78)",
              border: `1px solid ${color.hairline}`,
              fontFamily: font.family,
              transformOrigin: "0 100%",
              transform: `scale(${0.7 + 0.3 * label})`,
              opacity: frame < FIRST ? 0 : 1,
            }}
          >
            <FilmIcon id={sequence[index]} size={layout.wide ? 72 : 84} />
            <div>
              <div style={{ ...font.display, fontSize: layout.wide ? 38 : 44, color: color.paper }}>{look.name}</div>
              <div style={{ fontSize: layout.wide ? 20 : 24, color: color.mute, marginTop: 2 }}>{look.kind}</div>
            </div>
          </div>
        </div>
      </AbsoluteFill>

      {frame >= GRID ? (
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: layout.wide ? 70 : 80, padding: "0 60px" }}>
          <Words text={"18 film looks,\nbuilt from datasheets."} size={layout.wide ? 104 : layout.tall ? 96 : 84} stagger={2} start={GRID + 2} />
          <div style={{ display: "grid", gridTemplateColumns: `repeat(${cols}, ${icon}px)`, gap: layout.wide ? 22 : 26 }}>
            {all.map((id, i) => {
              const pop = s(GRID + i * 1, "pop");
              return (
                <div key={id} style={{ transform: `scale(${pop}) rotate(${(1 - pop) * -40}deg)` }}>
                  <FilmIcon id={id} size={icon} />
                </div>
              );
            })}
          </div>
        </AbsoluteFill>
      ) : null}
    </Stage>
  );
}
