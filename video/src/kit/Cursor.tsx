import type { Point } from "./light";

type Props = {
  /** The tip, in world units. */
  tip: Point;
  /** Its height in world units. */
  size: number;
  /** 1 at rest; less while the button is held down. */
  press?: number;
  opacity?: number;
};

/** A pointer arrow, black with a white edge, so it reads on the dark wall and on paper. */
export function Cursor({ tip, size, press = 1, opacity = 1 }: Props) {
  // The arrow's tip is at (3, 2) of its 24-unit box.
  const scale = size / 24;
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      style={{
        position: "absolute",
        left: tip.x - 3 * scale,
        top: tip.y - 2 * scale,
        opacity,
        overflow: "visible",
        transform: `scale(${press})`,
        transformOrigin: `${(3 / 24) * 100}% ${(2 / 24) * 100}%`,
        filter: `drop-shadow(0 ${size * 0.05}px ${size * 0.08}px rgba(0,0,0,0.5))`,
      }}
    >
      <path
        d="M3 2 L3 19.2 L7.4 15 L10.3 21.6 L13.5 20.2 L10.6 13.7 L16.6 13.7 Z"
        fill="#141010"
        stroke="#f3eee8"
        strokeWidth={1.4}
        strokeLinejoin="round"
      />
    </svg>
  );
}
