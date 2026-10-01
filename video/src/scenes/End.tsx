import { AbsoluteFill } from "remotion";
import { Words } from "../components/Kinetic";
import { Lens } from "../components/Lens";
import { Lockup } from "../components/Media";
import { Stage } from "../components/Stage";
import { useLayout, useSprings } from "../layout";
import { color, font } from "../theme";

/** The icon pops, the name wipes on, and the one address to remember. */
export function End() {
  const s = useSprings();
  const layout = useLayout();
  const icon = s(0, "pop");
  const lockup = s(8, "snap");
  const meta = s(22, "snap");
  return (
    <Stage glowY={0.36} pulses={[0, 14]}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: layout.tall ? 56 : 40, fontFamily: font.family }}>
        <div style={{ transform: `scale(${icon}) rotate(${(1 - icon) * -25}deg)` }}>
          <Lens size={layout.tall ? 320 : 250} tile glow={1} />
        </div>
        <div style={{ clipPath: `inset(0 ${(1 - lockup) * 100}% 0 0)` }}>
          <Lockup width={layout.tall ? 560 : 480} />
        </div>
        <Words text="redlamp.app" size={layout.tall ? 92 : 80} start={14} stagger={0} mode="pop" />
        <div style={{ fontSize: layout.tall ? 30 : 26, color: color.mute, opacity: meta, transform: `translateY(${(1 - meta) * 16}px)` }}>
          Early alpha preview · macOS 26 on Apple Silicon
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
