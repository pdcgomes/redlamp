import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { Words } from "../components/Kinetic";
import { Landscape } from "../components/Landscape";
import { glass } from "../components/Media";
import { Stage } from "../components/Stage";
import { Skel } from "../components/UI";
import { useLayout, useSprings } from "../layout";
import { color, font } from "../theme";

const edits = ["exposure  +0.85", "highlights  −68", "shadows  +52", "mask  sky · subject", "look  Portra 400"];
const LOCK = 16;
const SIDECAR = 24;

/** The raw file locks with a snap; the sidecar shoots out beside it and takes every edit. */
export function Originals() {
  const frame = useCurrentFrame();
  const s = useSprings();
  const layout = useLayout();
  const raw = s(0, "pop");
  // The open shackle lifts a little further, then slams shut.
  const lift = interpolate(frame, [LOCK - 6, LOCK - 1], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const shut = s(LOCK, "pop");
  const shackle = frame < LOCK ? -5 - 2 * lift : -7 * (1 - shut);
  const ring = interpolate(frame, [LOCK, LOCK + 12], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const side = s(SIDECAR, "pop");
  const text = layout.wide ? 1 : 1.15;

  return (
    <Stage glowY={0.2} pulses={[LOCK]}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: layout.wide ? 80 : 90, fontFamily: font.family }}>
        <Words text={layout.wide ? "Your originals stay untouched." : "Your originals\nstay untouched."} size={layout.wide ? 92 : layout.tall ? 96 : 80} stagger={2} />
        <div style={{ display: "flex", flexDirection: layout.tall ? "column" : "row", alignItems: "center", gap: 36 }}>
          <div style={{ ...glass, width: 500 * text, padding: 22, position: "relative", transform: `scale(${0.6 + 0.4 * raw})`, opacity: Math.min(1, raw * 2) }}>
            <div style={{ height: 280 * text, borderRadius: 12, overflow: "hidden" }}>
              <Landscape />
            </div>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 20 }}>
              <div>
                <div style={{ fontSize: 28 * text, fontWeight: 600, color: color.paper }}>DSC_0750.NEF</div>
                <Skel w={180 * text} h={12} style={{ marginTop: 12 }} />
              </div>
              <div style={{ position: "relative", width: 64, height: 72 }}>
                <div
                  style={{
                    position: "absolute",
                    left: -18,
                    top: -10,
                    width: 100,
                    height: 100,
                    borderRadius: 50,
                    border: `3px solid ${color.filament}`,
                    opacity: frame >= LOCK ? 1 - ring : 0,
                    transform: `scale(${0.5 + ring})`,
                  }}
                />
                <svg width="64" height="72" viewBox="0 0 28 32">
                  <path d="M 7 14 V 9 A 7 7 0 0 1 21 9 V 14" fill="none" stroke={color.ring} strokeWidth="3" strokeLinecap="round" transform={`translate(0 ${shackle})`} />
                  <rect x="3" y="14" width="22" height="16" rx="4" fill={color.steel} />
                  <circle cx="14" cy="22" r="2.4" fill={color.wall} />
                </svg>
              </div>
            </div>
          </div>
          <div
            style={{
              ...glass,
              width: 420 * text,
              padding: "24px 26px",
              transform: layout.tall ? `translateY(${(1 - side) * -160}px) scale(${0.7 + 0.3 * side})` : `translateX(${(1 - side) * -220}px) scale(${0.7 + 0.3 * side})`,
              opacity: Math.min(1, side * 2),
            }}
          >
            <div style={{ fontSize: 24 * text, fontWeight: 600, color: color.paper }}>DSC_0750.NEF.redlamp</div>
            <div style={{ fontSize: 17 * text, color: color.dim, marginTop: 4 }}>Sidecar · 2 KB</div>
            <div style={{ marginTop: 18, display: "flex", flexDirection: "column", gap: 10 }}>
              {edits.map((line, i) => {
                const pop = s(SIDECAR + 6 + i * 3, "pop");
                return (
                  <div key={line} style={{ fontFamily: font.mono, fontSize: 21 * text, color: color.ring, whiteSpace: "pre", transform: `translateX(${(1 - pop) * 30}px)`, opacity: Math.min(1, pop * 2) }}>
                    {line}
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
