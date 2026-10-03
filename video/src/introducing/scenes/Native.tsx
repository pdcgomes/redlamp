import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Capture } from "../components/Capture";
import { MacBook } from "../components/MacBook";
import { Room } from "../components/Room";
import { Camera } from "../components/Space";
import { Title } from "../components/Type";
import { ramp, track, useShape } from "../style";

/** The MacBook again, from its other side, with the film look on the display. */
export function Native({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape } = useShape();
  const wide = shape === "wide";
  const w = wide ? 900 : 820;
  const view = {
    rx: track(frame, [[0, 10], [length, 7]], (t) => t),
    ry: track(frame, [[0, 34], [length, 20]], (t) => t),
    x: wide ? -330 : 0,
    y: wide ? 215 : shape === "tall" ? 560 : 380,
    scale: track(frame, [[0, 0.96], [length, 1]], (t) => t),
  };
  const text = wide ? { left: 1100, top: 400 } : { left: 90, top: shape === "tall" ? 260 : 110 };
  return (
    <Room spot={{ x: wide ? 0.33 : 0.5, y: shape === "tall" ? 0.68 : 0.52, strength: ramp(frame, 0, 40) }}>
      <AbsoluteFill style={{ opacity: ramp(frame, 0, 20) }}>
        <Camera view={view}>
          <MacBook width={w} lean={14} turn={view.ry} screen={<Capture name="film-after" width={0.972 * w} />} />
        </Camera>
      </AbsoluteFill>
      <div style={{ position: "absolute", ...text }}>
        <Title title={"Built in Swift and Metal\nfor Apple Silicon."} sub={"Free and open source."} at={34} width={wide ? 760 : 900} />
      </div>
    </Room>
  );
}
