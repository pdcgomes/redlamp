import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Capture, regions } from "../components/Capture";
import { Room } from "../components/Room";
import { Camera } from "../components/Space";
import { Title } from "../components/Type";
import { BEAT, ease, font, ramp, track, useShape } from "../style";

/** ⌘ and K go down, and the command palette opens over the photo. */
export function Keyboard({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape } = useShape();
  const wide = shape === "wide";
  const press = (at: number) => ramp(frame, at, 5, ease.out) * (1 - ramp(frame, at + 9, 10, ease.out));
  const open = ramp(frame, 12 + 2 * BEAT, 40, ease.out);
  const palette = regions.palette;
  const paletteWidth = wide ? 900 : 940;
  const backdropWidth = paletteWidth * (1600 / palette.width);
  const keys = wide ? { left: 120, top: 250 } : { left: 90, top: shape === "tall" ? 190 : 90 };
  const text = wide ? { left: 120, top: 520 } : { left: 90, top: shape === "tall" ? 450 : 330 };
  return (
    <Room>
      <AbsoluteFill style={{ opacity: open }}>
        <Camera
          view={{
            rx: 3,
            ry: track(frame, [[0, -14], [length, -7]], (t) => t),
            x: wide ? 360 : 0,
            y: wide ? 0 : shape === "tall" ? 420 : 300,
            z: (1 - open) * -120,
          }}
          perspective={2600}
        >
          <div
            style={{
              position: "absolute",
              left: -paletteWidth / 2 - (palette.x / palette.width) * paletteWidth,
              top: -((palette.height / palette.width) * paletteWidth) / 2 - (palette.y / palette.width) * paletteWidth,
              filter: "blur(14px) brightness(0.45)",
              opacity: 0.85,
            }}
          >
            <Capture name="hero" width={backdropWidth} radius={24} />
          </div>
          <div
            style={{
              position: "absolute",
              left: -paletteWidth / 2,
              top: -((palette.height / palette.width) * paletteWidth) / 2,
              transform: `translateZ(60px) scale(${0.97 + 0.03 * open})`,
              borderRadius: 26,
              boxShadow: "0 40px 100px rgba(0,0,0,0.6)",
            }}
          >
            <Capture name="palette" region={palette} width={paletteWidth} radius={22} />
          </div>
        </Camera>
      </AbsoluteFill>
      <div style={{ position: "absolute", ...keys, display: "flex", gap: 22 }}>
        <Key label="⌘" sub="command" down={press(12 + BEAT)} />
        <Key label="K" down={press(12 + BEAT * 1.5)} />
      </div>
      <div style={{ position: "absolute", ...text }}>
        <Title title={"Every control\nfrom the keyboard."} sub={"⌘K finds any action or slider.\nType “exposure 0.7” to set it."} at={40} width={wide ? 700 : 900} />
      </div>
    </Room>
  );
}

/** A keycap, as Apple's keyboards draw them: dark, softly rounded, the legend near the top. */
function Key({ label, sub, down }: { label: string; sub?: string; down: number }) {
  const size = 132;
  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: 22,
        position: "relative",
        transform: `translateY(${down * 6}px)`,
        background: "linear-gradient(180deg, #2a2a2d, #1d1d20)",
        boxShadow: `inset 0 1px 0 rgba(255,255,255,0.12), inset 0 0 0 1px rgba(255,255,255,0.06), 0 ${10 - down * 7}px ${26 - down * 14}px rgba(0,0,0,0.6)`,
        fontFamily: font.family,
        color: "rgba(255,255,255,0.88)",
      }}
    >
      <div style={{ position: "absolute", left: 0, right: 0, top: sub ? 26 : 34, textAlign: "center", fontSize: sub ? 46 : 56, fontWeight: 500 }}>{label}</div>
      {sub ? <div style={{ position: "absolute", left: 0, right: 0, bottom: 20, textAlign: "center", fontSize: 18, color: "rgba(255,255,255,0.55)" }}>{sub}</div> : null}
    </div>
  );
}
