import type { CSSProperties, ReactNode } from "react";
import { color, font } from "../theme";

/** A placeholder bar for interface that isn't the point of the shot. */
export function Skel({ w, h = 10, style }: { w: number | string; h?: number; style?: CSSProperties }) {
  return <div style={{ width: w, height: h, borderRadius: h / 2, background: "rgba(243,238,232,0.09)", ...style }} />;
}

export function TrafficLights({ size = 13 }: { size?: number }) {
  return (
    <div style={{ display: "flex", gap: size * 0.7 }}>
      {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
        <span key={c} style={{ width: size, height: size, borderRadius: size / 2, background: c }} />
      ))}
    </div>
  );
}

/** The macOS arrow pointer, tip at (0, 0). */
export function Cursor({ x, y, size = 30, pressed = 0 }: { x: number; y: number; size?: number; pressed?: number }) {
  return (
    <svg
      width={size}
      height={size * 1.45}
      viewBox="0 0 20 29"
      style={{ position: "absolute", left: x - size * 0.06, top: y - size * 0.04, transform: `scale(${1 - 0.12 * pressed})`, transformOrigin: "0 0", filter: "drop-shadow(0 3px 5px rgba(0,0,0,0.5))", zIndex: 10 }}
    >
      <path d="M1 1 L1 23 L6.5 18 L10.5 27 L14 25.5 L10 16.8 L17.5 16.8 Z" fill="#fff" stroke="#111" strokeWidth="1.4" strokeLinejoin="round" />
    </svg>
  );
}

/** A physical key; `press` (0 to 1) pushes it down. */
export function Keycap({ children, size = 76, press = 0 }: { children: ReactNode; size?: number; press?: number }) {
  const depth = 6 * (1 - press);
  return (
    <div
      style={{
        minWidth: size,
        height: size,
        padding: `0 ${size * 0.2}px`,
        borderRadius: size * 0.22,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: font.family,
        fontSize: size * 0.42,
        fontWeight: 600,
        color: color.paper,
        background: "linear-gradient(180deg,#3a3230,#211b19)",
        border: `1px solid ${color.hairline}`,
        transform: `translateY(${6 - depth}px)`,
        boxShadow: `inset 0 1px 0 rgba(255,255,255,0.08), 0 ${depth}px 0 #120e0d, 0 14px 30px rgba(0,0,0,0.5)`,
      }}
    >
      {children}
    </div>
  );
}

export function Chip({ children, active = 0, size = 22, style }: { children: ReactNode; active?: number; size?: number; style?: CSSProperties }) {
  return (
    <span
      style={{
        fontFamily: font.family,
        fontSize: size,
        fontWeight: 500,
        padding: `${size * 0.42}px ${size * 0.8}px`,
        borderRadius: 999,
        whiteSpace: "nowrap",
        border: `1px solid ${active > 0.5 ? "transparent" : "rgba(243,238,232,0.18)"}`,
        background: `rgba(243,238,232,${0.05 + 0.9 * active})`,
        color: active > 0.5 ? "#1a1414" : color.paper,
        display: "inline-block",
        ...style,
      }}
    >
      {children}
    </span>
  );
}
