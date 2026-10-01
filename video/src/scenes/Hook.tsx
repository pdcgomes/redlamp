import { AbsoluteFill } from "remotion";
import { Words } from "../components/Kinetic";
import { Stage } from "../components/Stage";
import { useLayout } from "../layout";

/** No preamble: the first frame already moves. The line every Lightroom user wants to hear. */
export function Hook() {
  const layout = useLayout();
  const size = layout.wide ? 132 : layout.tall ? 128 : 110;
  return (
    <Stage glowY={0.42} pulses={[0, 15, 30]}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", padding: "0 70px" }}>
        <Words text={layout.wide ? "You already know\nhow to use it." : "You already\nknow how\nto use it."} size={size} stagger={3} />
      </AbsoluteFill>
    </Stage>
  );
}
