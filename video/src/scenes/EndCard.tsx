import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Lens } from "../components/Lens";
import { Lockup } from "../components/Media";
import { Stage } from "../components/Stage";
import { appear, useLayout } from "../layout";
import { color, font } from "../theme";

/** The app icon, the name and the address, then the light goes out. */
export function EndCard({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const layout = useLayout();
  const rise = spring({ frame: frame - 4, fps, config: { damping: 20, stiffness: 90 } });
  const out = interpolate(frame, [dur - 22, dur - 2], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <Stage glowY={0.4}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 40, flexDirection: "column" }}>
        <div style={{ transform: `scale(${0.9 + 0.1 * rise})`, opacity: rise }}>
          <Lens size={layout.tall ? 320 : 260} tile glow={1} />
        </div>
        <div style={{ opacity: appear(frame, 18, 24) }}>
          <Lockup width={layout.tall ? 520 : 480} />
        </div>
        <div style={{ fontFamily: font.family, textAlign: "center", opacity: appear(frame, 32, 24) }}>
          <div style={{ ...font.display, fontSize: 44, color: color.paper }}>redlamp.app</div>
          <div style={{ marginTop: 12, fontSize: 24, color: color.mute }}>Open source · MPL-2.0 · github.com/pdcgomes/redlamp</div>
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ background: "#000", opacity: out }} />
    </Stage>
  );
}
