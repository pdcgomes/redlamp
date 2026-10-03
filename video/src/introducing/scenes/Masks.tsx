import { AbsoluteFill, useCurrentFrame } from "remotion";
import { render, useManifest } from "../assets";
import { Capture, editor } from "../components/Capture";
import { BackgroundIcon, PersonIcon } from "../components/Icons";
import { Room } from "../components/Room";
import { Sheet, Tag } from "../components/Sheet";
import { Camera } from "../components/Space";
import { Develop, Title } from "../components/Type";
import { ease, font, ink, ramp, track, type as typeScale, useShape } from "../style";

/**
 * A portrait comes apart along its AI masks: the subject, cut out by the Subject mask, lifts off
 * the background cut by its inverse, the Background mask, both as the engine wrote them. Where
 * the subject was, the background keeps a faint ghost of it. Then the masks in the app.
 */
export function Masks({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape } = useShape();
  const cutout = useManifest().cutout;
  const wide = shape === "wide";
  const s = typeScale[shape];
  const swap = length - 165;

  const height = wide ? 680 : shape === "tall" ? 900 : 700;
  const width = (height * 2) / 3;
  const apart = ramp(frame, 36, 120, ease.move) * (1 - ramp(frame, swap - 10, 60, ease.inOut));
  const view = {
    rx: 5 * apart,
    ry: (wide ? -36 : -30) * apart - 5 * ramp(frame, 150, swap - 150, (t) => t),
    x: wide ? 360 : 150 * apart,
    y: wide ? 10 : shape === "tall" ? 260 : 150,
  };
  const leave = ramp(frame, swap - 6, 40, ease.inOut);
  const enter = ramp(frame, swap + 14, 46, ease.out);
  const tagShown = ramp(frame, 120, 26) * (1 - ramp(frame, swap - 30, 24));
  const text = wide ? { left: 120, top: 330 } : { left: 90, top: shape === "tall" ? 150 : 80 };
  const windowWidth = wide ? 1060 : 1000;
  return (
    <Room>
      {cutout ? (
        <AbsoluteFill style={{ opacity: 1 - leave, filter: leave > 0 ? `blur(${leave * 8}px)` : undefined }}>
          <Camera view={view} perspective={2300}>
            <Sheet src={render(cutout.photo)} mask={render(cutout.subject)} width={width} height={height} opacity={0.16 * apart} edge={0} />
            <Sheet src={render(cutout.photo)} mask={render(cutout.background)} width={width} height={height} z={0.5}>
              <Tag
                view={view}
                x={width - 14}
                y={height * 0.07}
                z={2}
                anchor="right"
                icon={<BackgroundIcon size={s.label * 1.05} />}
                title="Background"
                opacity={tagShown}
              />
            </Sheet>
            <Sheet src={render(cutout.photo)} mask={render(cutout.subject)} width={width} height={height} z={300 * apart} glow={0.45 * apart} edge={0}>
              <Tag
                view={view}
                x={width * 0.2}
                y={height * 0.2}
                z={4}
                anchor="right"
                icon={<PersonIcon size={s.label * 1.05} />}
                title="Subject"
                opacity={tagShown}
              />
            </Sheet>
          </Camera>
        </AbsoluteFill>
      ) : null}
      <AbsoluteFill style={{ opacity: enter }}>
        <Camera
          view={{
            rx: 4,
            ry: track(frame, [[swap, -16], [length, -9]], (t) => t),
            x: wide ? 330 : 0,
            y: wide ? 0 : shape === "tall" ? 300 : 180,
            z: (1 - enter) * -160,
          }}
          perspective={2600}
        >
          <div style={{ position: "absolute", left: -windowWidth / 2, top: (-windowWidth * editor.height) / editor.width / 2 }}>
            <Capture name="masks-people" width={windowWidth} radius={12} style={{ boxShadow: "0 50px 120px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08)" }} />
          </div>
        </Camera>
      </AbsoluteFill>
      <AbsoluteFill>
        <div style={{ position: "absolute", ...text }}>
          <Title
            title={"Masks that know\nwhat's in the photo."}
            sub={"Subject, Sky, Background and People,\ndown to eyes and teeth."}
            at={30}
            width={wide ? 700 : 900}
          />
          <Develop at={swap + 40} duration={36}>
            <div style={{ ...font.text, fontSize: s.sub, color: ink.headline, marginTop: s.sub * 0.9 }}>All on your Mac.</div>
          </Develop>
        </div>
      </AbsoluteFill>
    </Room>
  );
}
