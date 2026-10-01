import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { noise2D } from "@remotion/noise";
import { Caption } from "../components/Caption";
import { Lens } from "../components/Lens";
import { Lockup } from "../components/Media";
import { Stage } from "../components/Stage";
import { appear, useLayout } from "../layout";
import { easeOut } from "../theme";

/** Darkness. The safelight's filament warms up, flickers once, and settles; the name appears. */
export function ColdOpen({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const layout = useLayout();
  const warm = interpolate(frame, [8, 72], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: easeOut });
  const flicker = frame < 80 ? 0.82 + 0.18 * noise2D("flicker", frame / 3, 0) : 1;
  const glow = warm * flicker;
  const lift = interpolate(frame, [92, 128], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: easeOut });
  const lensSize = layout.tall ? 520 : 420;
  const scale = 0.92 + 0.08 * appear(frame, 0, 90);
  return (
    <Stage glow={glow} glowY={0.36}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div style={{ transform: `translateY(${-lift * (layout.tall ? 180 : 120)}px) scale(${scale})` }}>
          <Lens size={lensSize} glow={glow} />
        </div>
      </AbsoluteFill>
      <AbsoluteFill
        style={{ alignItems: "center", justifyContent: "center", paddingTop: layout.tall ? 560 : 400, gap: 36 }}
      >
        <div style={{ opacity: appear(frame, 104, 30), transform: `translateY(${(1 - appear(frame, 104, 30)) * 18}px)` }}>
          <Lockup width={layout.tall ? 520 : 460} />
        </div>
        <Caption
          title="Work by the light that never fogs the paper."
          start={132}
          align="center"
          size={layout.tall ? 40 : 34}
          style={{ maxWidth: layout.tall ? 820 : 1100, opacity: 0.9 }}
        />
      </AbsoluteFill>
      <AbsoluteFill style={{ background: "#000", opacity: interpolate(frame, [0, 10, dur - 1], [1, 0, 0]) }} />
    </Stage>
  );
}
