import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Capture } from "../components/Capture";
import { MacBook } from "../components/MacBook";
import { Room } from "../components/Room";
import { Camera } from "../components/Space";
import { Title } from "../components/Type";
import { ramp, track, useShape } from "../style";

/** How far the lid leans back, and the display's centre above the hinge, in lid widths. */
const LEAN = 14;
const CAPTURE_CENTRE = 0.3468 - 0.0104;

/**
 * A MacBook Pro turns out of the dark with Redlamp lit on its display, then the camera pushes
 * into the display until the editor fills the frame, where the next scene picks it up flat. The
 * push ends before the dissolve, so both pictures hold still and match while they cross.
 */
export function Reveal({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape, width } = useShape();
  const w = shape === "wide" ? 900 : shape === "tall" ? 740 : 820;
  const landed = length - 26;
  const push = landed - 72;
  // At the end of the push the capture is frontal and as wide as the frame (a little over).
  const end = (width * 1.02) / (0.972 * w);
  const at = shape === "wide" ? { x: 330, y: 215 } : { x: shape === "tall" ? 30 : 10, y: shape === "tall" ? 460 : 300 };
  const view = {
    rx: track(frame, [[0, 13], [push, 9], [landed, LEAN]]),
    ry: track(frame, [[0, -40], [push, -19], [landed, 0]]),
    rz: 0,
    x: track(frame, [[0, at.x + 40], [push, at.x], [landed, 0]]),
    y: track(frame, [[0, at.y + 30], [push, at.y], [landed, CAPTURE_CENTRE * w * end]]),
    scale: track(frame, [[0, 0.9], [push, 1], [landed, end]]),
  };
  const power = ramp(frame, 24, 40);
  const text = shape === "wide" ? { left: 120, top: 400 } : { left: 90, top: shape === "tall" ? 260 : 120 };
  return (
    <Room
      light={ramp(frame, 0, 70)}
      spot={{ x: shape === "wide" ? 0.67 : 0.5, y: shape === "tall" ? 0.66 : 0.52, strength: ramp(frame, 10, 80) * (1 - ramp(frame, push, 50)) }}
    >
      <AbsoluteFill style={{ opacity: ramp(frame, 0, 34) }}>
        <Camera view={view}>
          <MacBook width={w} lean={LEAN} power={power} turn={view.ry} screen={<Capture name="hero" width={0.972 * w} />} />
        </Camera>
      </AbsoluteFill>
      <div style={{ position: "absolute", ...text }}>
        <Title
          title={"The raw editor\nyou already know."}
          sub={"Lightroom's panels, sliders and shortcuts,\nnative on the Mac."}
          at={62}
          until={push - 24}
          width={shape === "wide" ? 820 : 900}
        />
      </div>
    </Room>
  );
}