import type { CSSProperties, ReactNode } from "react";
import { glass } from "../../components/Media";
import { color, font } from "../../theme";
import { canvas, type } from "../canvas";
import { useShotSpace, type Region } from "./Shot";

type RingProps = {
  /** What to ring, in window points, inside the shot the ring is placed in. */
  at: Region;
  /** How far the ring stands off what it rings, in canvas points. */
  pad?: number;
  radius?: number;
  /** Darken the rest of the shot, so the eye goes to the ring. */
  dim?: boolean;
};

/** A paper-white ring around part of a shot. Never red: the glow is the image's one red light. */
export function Ring({ at, pad = 6, radius = 12, dim = false }: RingProps) {
  const { region, scale } = useShotSpace();
  return (
    <div
      style={{
        position: "absolute",
        left: (at.x - region.x) * scale - pad,
        top: (at.y - region.y) * scale - pad,
        width: at.width * scale + pad * 2,
        height: at.height * scale + pad * 2,
        borderRadius: radius,
        border: `3px solid ${color.paper}`,
        boxShadow: dim ? "0 0 0 4000px rgba(10,7,7,0.58)" : "0 0 24px rgba(0,0,0,0.4)",
      }}
    />
  );
}

/** A thin paper-white line from a dot at `from` to `to`, in canvas points. */
export function Leader({ from, to }: { from: [number, number]; to: [number, number] }) {
  return (
    <svg
      width={canvas.width}
      height={canvas.height}
      style={{ position: "absolute", left: 0, top: 0, overflow: "visible", pointerEvents: "none" }}
    >
      <line x1={from[0]} y1={from[1]} x2={to[0]} y2={to[1]} stroke={color.paper} strokeWidth={2.5} strokeLinecap="round" />
      <circle cx={from[0]} cy={from[1]} r={7} fill={color.paper} />
    </svg>
  );
}

/** A drawn pill naming a feature. */
export function Chip({ children, size = type.text, style }: { children: ReactNode; size?: number; style?: CSSProperties }) {
  return (
    <div
      style={{
        ...glass,
        borderRadius: 999,
        padding: `${size * 0.28}px ${size * 0.62}px`,
        display: "inline-flex",
        alignItems: "center",
        gap: size * 0.3,
        fontFamily: font.family,
        fontSize: size,
        lineHeight: 1.1,
        color: color.paper,
        whiteSpace: "nowrap",
        boxShadow: "inset 0 1px 0 rgba(255,255,255,0.06), 0 14px 34px rgba(0,0,0,0.45)",
        ...style,
      }}
    >
      {children}
    </div>
  );
}
