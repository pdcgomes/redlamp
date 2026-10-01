import { AbsoluteFill } from "remotion";
import { Words } from "../components/Kinetic";
import { Stage } from "../components/Stage";
import { BEAT, useLayout, useSprings } from "../layout";

const lines = ["Free.", "Open source.", "Native to your Mac."];
const narrow = ["Free.", "Open source.", "Native to\nyour Mac."];
const OUT = BEAT * 3;

/** Three plain facts on the beat, then the one idea behind them. */
export function Essentials() {
  const s = useSprings();
  const layout = useLayout();
  const size = layout.wide ? 140 : layout.tall ? 128 : 108;
  const final = s(OUT + 6, "pop");
  return (
    <Stage glowY={0.45} pulses={[0, BEAT, BEAT * 2, OUT + 6]}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 10, padding: "0 60px" }}>
        {(layout.wide ? lines : narrow).map((line, i) => (
          <Words key={line} text={line} size={size} start={i * BEAT} stagger={2} out={OUT} tone={i === 2 ? "paper" : "mute"} />
        ))}
      </AbsoluteFill>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", padding: "0 60px" }}>
        <div style={{ transform: `scale(${0.6 + 0.4 * final})`, opacity: Math.min(1, final * 2) }}>
          <Words text={layout.wide ? "Just the essentials." : "Just the\nessentials."} size={size * 1.15} start={OUT + 6} stagger={3} mode="pop" />
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
