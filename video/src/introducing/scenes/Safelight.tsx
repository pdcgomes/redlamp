import { AbsoluteFill, Img, staticFile, useCurrentFrame } from "remotion";
import { Lens } from "../../components/Lens";
import { Room } from "../components/Room";
import { Develop } from "../components/Type";
import { ease, font, ink, mix, ramp, type as typeScale, useShape } from "../style";

/** The horizontal lockup's viewBox, and its mark: a ring of radius 22 round (24, 24). */
const LOCKUP = { width: 192.37, height: 48, mark: 24, ring: 44 };

/** Where the logo rises to, from frame `at` over `duration` frames: its width and centre in pixels. */
export type Rise = { at: number; duration: number; width: number; y: number };

/**
 * Darkness, then the safelight warms up and lights the wall, and two lines say what it is for.
 * The lens then settles into the logo's mark, where the flat lockup takes over: the brand's mark
 * never glows itself. With `rise` (the app's welcome, `Welcome.tsx`), the logo then rises to the
 * top of the frame, and the line under it goes.
 */
export function Safelight({ length, rise }: { length: number; rise?: Rise }) {
  const frame = useCurrentFrame();
  const { shape, width, height } = useShape();
  const size = typeScale[shape];
  // The flat logo lands on the third beat of the scene's last bar.
  const lockAt = length - 87;
  const settle = ramp(frame, lockAt, 34, ease.inOut);
  const warm = ramp(frame, 6, 120, ease.inOut);
  const risen = rise ? ramp(frame, rise.at, rise.duration) : 0;

  const lockupWidth = mix(shape === "wide" ? 560 : 620, rise?.width ?? 0, risen);
  const unit = lockupWidth / LOCKUP.width;
  const lockup = { left: (width - lockupWidth) / 2, top: mix(height * 0.47, rise?.y ?? 0, risen) - (LOCKUP.height * unit) / 2 };
  const markCentre = { x: lockup.left + LOCKUP.mark * unit, y: lockup.top + LOCKUP.mark * unit };

  // The lens: its bezel (66 of its 100 units, centred at 50, 47) shrinks onto the mark's ring.
  const lensStart = shape === "wide" ? 210 : 260;
  const lensEnd = (LOCKUP.ring * unit) / 0.66;
  const lensSize = mix(lensStart * mix(0.94, 1, ramp(frame, 0, lockAt, (t) => t)), lensEnd, settle);
  const centre = {
    x: mix(width / 2, markCentre.x, settle),
    y: mix(height * (shape === "wide" ? 0.36 : 0.38), markCentre.y, settle),
  };
  const lensOpacity = ramp(frame, 0, 20) * (1 - ramp(frame, lockAt + 28, 14));
  const flat = ramp(frame, lockAt + 26, 16);
  const words = ramp(frame, lockAt + 14, 30, ease.out);

  const lineTop = height * (shape === "wide" ? 0.6 : 0.58);
  const line = { position: "absolute" as const, left: 0, right: 0, top: lineTop, textAlign: "center" as const };
  const lineStyle = { ...font.display, fontSize: size.headline * 0.62, lineHeight: 1.18, color: ink.headline, whiteSpace: "pre-line" as const };
  return (
    <Room tone="safelight" glow={warm * (1 - 0.35 * settle) * (1 - 0.3 * risen)} glowX={centre.x / width} glowY={centre.y / height}>
      <AbsoluteFill style={{ fontFamily: font.family }}>
        <div style={{ position: "absolute", left: centre.x - lensSize / 2, top: centre.y - lensSize * 0.47, opacity: lensOpacity }}>
          <Lens size={lensSize} glow={warm} />
        </div>
        <div style={line}>
          <Develop at={44} until={152} duration={40}>
            <div style={lineStyle}>{shape === "wide" ? "In the darkroom, there's one light you can work by." : "In the darkroom, there's one\nlight you can work by."}</div>
          </Develop>
        </div>
        <div style={line}>
          <Develop at={162} until={lockAt - 8} duration={40}>
            <div style={lineStyle}>It shows you everything, and harms nothing.</div>
          </Develop>
        </div>
        <div style={{ position: "absolute", left: lockup.left, top: lockup.top, width: lockupWidth, height: LOCKUP.height * unit }}>
          <Img
            src={staticFile("synced/brand/logo/redlamp-lockup.svg")}
            style={{
              position: "absolute",
              inset: 0,
              width: "100%",
              height: "100%",
              opacity: words,
              clipPath: `inset(0 0 0 ${mix(30, 0, flat)}%)`,
              filter: `blur(${(1 - words) * 6}px)`,
            }}
          />
        </div>
        <div style={{ position: "absolute", left: 0, right: 0, top: lockup.top + LOCKUP.height * unit + size.sub * 1.4, textAlign: "center" }}>
          <Develop at={lockAt + 40} until={rise?.at} duration={36}>
            <div style={{ ...font.text, fontSize: size.sub, color: ink.sub }}>A raw photo editor for the Mac.</div>
          </Develop>
        </div>
      </AbsoluteFill>
    </Room>
  );
}
