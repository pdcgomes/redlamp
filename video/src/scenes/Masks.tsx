import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { Words } from "../components/Kinetic";
import { Landscape } from "../components/Landscape";
import { Stage } from "../components/Stage";
import { Chip } from "../components/UI";
import { useLayout, useSprings } from "../layout";

const kinds = ["Linear", "Radial", "Brush", "Range", "Subject", "Sky", "Background", "People", "Objects", "Depth"];
const SKY = 10;
const SUBJECT = 48;

/** Sky, then Subject: each detected on-device, shown under the red overlay, then adjusted. */
export function Masks() {
  const frame = useCurrentFrame();
  const s = useSprings();
  const layout = useLayout();
  const box = layout.wide ? { w: 1300, h: 640 } : layout.tall ? { w: 980, h: 1060 } : { w: 960, h: 600 };
  const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

  const skyEdge = s(SKY + 2, "drag");
  const skyOverlay = interpolate(frame, [SKY, SKY + 2, SKY + 22, SKY + 28], [0, 1, 1, 0], clamp);
  const skyApply = s(SKY + 22, "snap");
  const scan = interpolate(frame, [SUBJECT, SUBJECT + 10], [0.05, 0.8], clamp);
  const treeOverlay = interpolate(frame, [SUBJECT + 8, SUBJECT + 11, SUBJECT + 24, SUBJECT + 30], [0, 1, 1, 0], clamp);
  const treePop = s(SUBJECT + 8, "pop");
  const treeApply = s(SUBJECT + 24, "snap");
  const card = s(0, "pop");
  const punch = (at: number) => 1 + 0.025 * (1 - s(at, "pop")) * (frame >= at ? 1 : 0);
  const wave = (i: number) => interpolate(frame, [84 + i * 1.5, 87 + i * 1.5, 92 + i * 1.5], [0, 1, 0], clamp);

  return (
    <Stage glowY={0.06} pulses={[SKY + 22, SUBJECT + 24]}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: layout.wide ? 40 : 50, padding: "0 50px" }}>
        <Words text={layout.wide ? "Masks, with on-device AI." : "Masks, with\non-device AI."} size={layout.wide ? 78 : layout.tall ? 84 : 62} stagger={2} />
        <div
          style={{
            width: box.w,
            height: box.h,
            borderRadius: 22,
            overflow: "hidden",
            boxShadow: "0 30px 80px rgba(0,0,0,0.6)",
            transform: `translateY(${(1 - card) * 200}px) scale(${(0.9 + 0.1 * card) * punch(SKY + 22) * punch(SUBJECT + 24)})`,
          }}
        >
          <Landscape
            sky={{ exposure: -0.55 * skyApply, saturation: 0.35 * skyApply, warmth: -0.12 * skyApply }}
            tree={{ exposure: 0.22 * treeApply, warmth: 0.55 * treeApply, highlights: 0.6 * treeApply }}
            skyOverlay={{ edge: skyEdge, opacity: skyOverlay }}
            treeOverlay={treeOverlay * Math.min(1, treePop * 1.5)}
            scan={frame >= SUBJECT && frame <= SUBJECT + 10 ? scan : -1}
          />
        </div>
        <div style={{ display: "flex", gap: 12, flexWrap: "wrap", justifyContent: "center", maxWidth: layout.wide ? 1500 : 980 }}>
          {kinds.map((kind, i) => {
            const pop = s(4 + i * 1.2, "pop");
            const on = kind === "Sky" ? interpolate(frame, [SKY - 2, SKY, SKY + 30, SKY + 34], [0, 1, 1, 0], clamp) : kind === "Subject" ? interpolate(frame, [SUBJECT - 2, SUBJECT, SUBJECT + 30, SUBJECT + 34], [0, 1, 1, 0], clamp) : 0;
            return (
              <div key={kind} style={{ transform: `scale(${(0.5 + 0.5 * pop) * (1 + 0.08 * on + 0.08 * wave(i))})`, opacity: Math.min(1, pop * 2) }}>
                <Chip active={Math.max(on, wave(i))} size={layout.wide ? 24 : 26}>
                  {kind}
                </Chip>
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
