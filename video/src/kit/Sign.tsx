import { color } from "../theme";
import { StarGlyph } from "./GitHubBadge";
import type { Point } from "./light";
import { textWidth } from "./measure";
import type { SignFrame } from "./rope";

/** The sign as the website draws it, in website pixels: its padding, type and the eyelet's place. */
const SIGN = { padX: 14, padTop: 17, padBottom: 8, text: 14, line: 20, eyelet: 9, star: 14, gap: 6, radius: 8 };

/** The sign's size in website pixels, and how far below its top edge the rope is tied. */
export function signSize(text: string): { width: number; height: number; eyelet: number } {
  return {
    width: Math.ceil(SIGN.padX * 2 + SIGN.star + SIGN.gap + textWidth(text, SIGN.text, 600)),
    height: SIGN.padTop + SIGN.line + SIGN.padBottom,
    eyelet: SIGN.eyelet,
  };
}

type Props = {
  frame: SignFrame | null;
  /** Where the anchor's resting point is in the scene, and the scene's units per website pixel. */
  origin: Point;
  scale: number;
  text: string;
};

/**
 * The paper sign on its rope, lit from above left, with a steel eyelet: the website's "Please star
 * us!" (web/components/site/StarNudge.tsx). Nothing until it drops.
 */
export function Sign({ frame, origin, scale, text }: Props) {
  if (!frame) return null;
  const { pose, rope } = frame;
  const { width, height } = signSize(text);
  const at = (p: Point) => `${(origin.x + p.x * scale).toFixed(2)} ${(origin.y + p.y * scale).toFixed(2)}`;
  let d = `M${at(rope[0])}`;
  for (let i = 1; i < rope.length - 1; i += 1) {
    d += ` Q${at(rope[i])} ${at({ x: (rope[i].x + rope[i + 1].x) / 2, y: (rope[i].y + rope[i + 1].y) / 2 })}`;
  }
  d += ` L${at(rope[rope.length - 1])}`;
  return (
    <>
      <svg style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }} width={1} height={1}>
        <path d={d} fill="none" stroke="rgba(217,208,203,0.7)" strokeWidth={1.5 * scale} strokeLinecap="round" />
      </svg>
      <div style={{ position: "absolute", left: origin.x + pose.x * scale, top: origin.y + pose.y * scale }}>
        {/* Its shadow on the wall, a gradient rather than a blurred box-shadow, which is slow to rasterise. */}
        <div
          style={{
            position: "absolute",
            left: -width * 0.62,
            top: -height * 0.45,
            width: width * 1.24,
            height: height * 1.7,
            transform: `rotate(${pose.angle}rad) scale(${scale})`,
            transformOrigin: `${width * 0.62}px ${height * 0.45}px`,
            background: "radial-gradient(closest-side, rgba(0,0,0,0.5), rgba(0,0,0,0.2) 60%, rgba(0,0,0,0))",
          }}
        />
        <div
          style={{
            position: "absolute",
            left: -width / 2,
            top: -height / 2,
            width,
            height,
            boxSizing: "border-box",
            transform: `rotate(${pose.angle}rad) scale(${scale})`,
            borderRadius: SIGN.radius,
            background: `linear-gradient(135deg, ${color.paper}, ${color.ring})`,
            padding: `${SIGN.padTop}px ${SIGN.padX}px ${SIGN.padBottom}px`,
            display: "flex",
            alignItems: "center",
            gap: SIGN.gap,
            color: color.ink,
            fontFamily: "Inter, sans-serif",
            fontSize: SIGN.text,
            lineHeight: `${SIGN.line}px`,
            fontWeight: 600,
            whiteSpace: "nowrap",
          }}
        >
          <span
            style={{
              position: "absolute",
              top: 5,
              left: "50%",
              width: 8,
              height: 8,
              marginLeft: -4,
              borderRadius: 4,
              background: color.wall,
              boxShadow: `0 0 0 1px ${color.steel}`,
            }}
          />
          <StarGlyph size={SIGN.star} />
          {text}
        </div>
      </div>
    </>
  );
}
