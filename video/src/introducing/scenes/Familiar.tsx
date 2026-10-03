import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Capture, editor, type Region, regions } from "../components/Capture";
import { Room } from "../components/Room";
import { Title } from "../components/Type";
import { ease, mix, ramp, track, useShape } from "../style";

type Shot = { name: string; focus: { x: number; y: number }; scale: number; at: { x: number; y: number } };

/**
 * The editor, flat, where the push into the MacBook left it. The camera glides to Basic's Tone
 * sliders, the rest of the window dims, then the ⌘/ sheet lists the shortcuts.
 */
export function Familiar({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape, width, height } = useShape();
  const wide = shape === "wide";
  const swap = Math.round(length * 0.52);

  const tone = regions.basicTone;
  const sheet = regions.shortcuts;
  const start: Shot = { name: "hero", focus: { x: editor.width / 2, y: editor.height / 2 }, scale: (width * 1.02) / editor.width, at: { x: width / 2, y: height / 2 } };
  const sliders: Shot = {
    name: "hero",
    focus: centre(tone),
    scale: wide ? 2.45 : 3.1,
    at: wide ? { x: width * 0.69, y: height * 0.5 } : { x: width / 2, y: height * (shape === "tall" ? 0.62 : 0.6) },
  };
  const list: Shot = {
    name: "shortcuts",
    focus: centre(sheet),
    scale: wide ? 0.98 : 0.92,
    at: wide ? { x: width * 0.63, y: height * 0.5 } : { x: width / 2, y: height * (shape === "tall" ? 0.62 : 0.64) },
  };

  // Still while the push dissolves into it, then away to the sliders.
  const go = ramp(frame, 26, swap - 54, ease.move);
  const back = ramp(frame, swap - 10, 70, ease.move);
  const pose = {
    fx: mix(mix(start.focus.x, sliders.focus.x, go), list.focus.x, back),
    fy: mix(mix(start.focus.y, sliders.focus.y, go), list.focus.y, back),
    s: mix(mix(start.scale, sliders.scale, go), list.scale, back),
    ax: mix(mix(start.at.x, sliders.at.x, go), list.at.x, back),
    ay: mix(mix(start.at.y, sliders.at.y, go), list.at.y, back),
  };
  const spot = ramp(frame, 60, 50) * (1 - ramp(frame, swap - 20, 30));
  const crossfade = ramp(frame, swap - 6, 30, ease.inOut);
  const drift = track(frame, [[swap, 0], [length, 1]], (t) => t);

  const place = (r: Region) => ({
    left: pose.ax + (r.x - pose.fx) * pose.s,
    top: pose.ay + (r.y - pose.fy) * pose.s,
    width: r.width * pose.s,
    height: r.height * pose.s,
  });
  const window = place({ x: 0, y: 0, ...editor });
  const hole = place(tone);
  const text = wide ? { left: 120, top: 360 } : { left: 90, top: shape === "tall" ? 190 : 90 };
  return (
    <Room light={0.6}>
      <div style={{ position: "absolute", ...window, transform: `scale(${1 + 0.015 * drift})`, transformOrigin: "50% 50%" }}>
        <Capture name="hero" width={window.width} radius={10 * pose.s} style={{ position: "absolute", inset: 0 }} />
        <Capture name="shortcuts" width={window.width} radius={10 * pose.s} style={{ position: "absolute", inset: 0, opacity: crossfade }} />
      </div>
      <div
        style={{
          position: "absolute",
          left: hole.left - 10,
          top: hole.top - 10,
          width: hole.width + 20,
          height: hole.height + 20,
          borderRadius: 18,
          boxShadow: `0 0 90px 3000px rgba(5,5,6,${0.62 * spot})`,
        }}
      />
      <AbsoluteFill
        style={{
          background: wide
            ? `linear-gradient(90deg, rgba(8,8,9,${0.92 * Math.max(go, 0.001)}) 0%, rgba(8,8,9,${0.75 * go}) 30%, transparent 48%)`
            : `linear-gradient(180deg, rgba(8,8,9,${0.92 * go}) 0%, rgba(8,8,9,${0.7 * go}) 26%, transparent 44%)`,
        }}
      />
      <div style={{ position: "absolute", ...text }}>
        <Title
          title={"Nothing to relearn."}
          sub={wide ? "Lightroom's panel order, slider names\nand ranges, and its shortcuts." : "Lightroom's panel order, slider\nnames and ranges, and its shortcuts."}
          at={64}
          until={swap - 22}
          width={wide ? 700 : 900}
        />
      </div>
      <div style={{ position: "absolute", ...text }}>
        <Title title={"The same shortcuts."} sub={"⌘/ lists all 83 of\nLightroom Classic's shortcuts."} at={swap + 24} width={wide ? 640 : 900} />
      </div>
    </Room>
  );
}

function centre(r: Region) {
  return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
}
