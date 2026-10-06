import { color } from "../theme";
import { textWidth } from "./measure";
import type { Point } from "./light";

/**
 * The website header's GitHub button (web/components/site/SiteHeader.tsx) on its own: the
 * GitHub mark, "GitHub", and the star with the repository's count. The shot lands on it.
 */
export type BadgeState = {
  centre: Point;
  /** Its height in world units; everything inside is sized from it. */
  height: number;
  /** The star count, or null to show the star alone. */
  count: number | null;
  /** 0 to 1: how far the count has rolled on to `count + 1`. */
  roll: number;
  scale: number;
  /** 0 to 1: the hit's light on the border, and the halo round it. */
  lit: number;
  halo: number;
  /** The star's spin as the shot lands, and how lit it is (0 the badge's grey, 1 filament). */
  star: { rotate: number; scale: number; lit: number };
};

const LABEL = "GitHub";

/** The badge's unscaled size, so the light can be drawn round it. */
export function badgeSize(height: number, count: number | null): { width: number; height: number } {
  const h = height;
  const label = textWidth(LABEL, 0.4 * h, 600);
  const left = 0.36 * h + 0.44 * h + 0.2 * h + label;
  const right = count === null ? 0.24 * h + 0.38 * h : 0.26 * h + 0.03 * h + 0.24 * h + 0.38 * h + 0.14 * h + countWidth(count, h);
  return { width: left + right + 0.36 * h, height: h };
}

/**
 * Where the star's centre sits, and where a rope hangs from (under the star and its count, 3
 * website pixels above the foot, as on the website), relative to the badge's centre unscaled.
 */
export function badgeParts(height: number, count: number | null): { star: Point; anchor: Point } {
  const h = height;
  const { width } = badgeSize(h, count);
  const groupLeft = -width / 2 + 0.36 * h + 0.44 * h + 0.2 * h + textWidth(LABEL, 0.4 * h, 600) + (count === null ? 0.24 * h : 0.53 * h);
  const groupWidth = count === null ? 0.38 * h : 0.38 * h + 0.14 * h + countWidth(count, h);
  return {
    star: { x: groupLeft + 0.19 * h, y: 0 },
    anchor: { x: groupLeft + groupWidth / 2, y: h / 2 - 3 * (h / 30) },
  };
}

function countWidth(count: number, h: number): number {
  return Math.max(textWidth(formatCount(count), 0.4 * h, 500), textWidth(formatCount(count + 1), 0.4 * h, 500));
}

/** As the website writes the count (web/lib/github.ts). */
export function formatCount(count: number): string {
  return count >= 1000 ? `${(count / 1000).toFixed(count >= 10000 ? 0 : 1)}k` : String(count);
}

export function GitHubBadge({ centre, height: h, count, roll, scale, lit, halo, star }: BadgeState) {
  const { width } = badgeSize(h, count);
  const u = h / 30;
  const border = mix([243, 238, 232, 0.16], [255, 176, 138, 0.95], lit);
  const starColour = mixHex(color.mute, color.filament, star.lit);
  return (
    <div
      style={{
        position: "absolute",
        left: centre.x - width / 2,
        top: centre.y - h / 2,
        width,
        height: h,
        boxSizing: "border-box",
        borderRadius: h / 2,
        border: `${Math.max(1, 1.2 * u)}px solid ${border}`,
        background: "linear-gradient(160deg, #2c2422 0%, #1c1615 55%, #151010 100%)",
        boxShadow: [
          `inset 0 ${u}px 0 rgba(255,255,255,0.07)`,
          `0 ${10 * u}px ${24 * u}px rgba(0,0,0,0.5)`,
          `0 0 0 ${u}px rgba(255,176,138,${0.85 * halo})`,
          `0 0 ${18 * u}px ${3 * u}px rgba(224,64,46,${0.7 * halo})`,
          `0 0 ${46 * u}px ${12 * u}px rgba(224,64,46,${0.35 * halo})`,
        ].join(", "),
        transform: `scale(${scale})`,
        display: "flex",
        alignItems: "center",
        padding: `0 ${0.36 * h}px`,
        color: color.paper,
        fontFamily: "Inter, sans-serif",
        whiteSpace: "nowrap",
      }}
    >
      <GitHubMark size={0.44 * h} />
      <span style={{ marginLeft: 0.2 * h, fontSize: 0.4 * h, fontWeight: 600, letterSpacing: "-0.01em" }}>{LABEL}</span>
      <span
        style={{
          display: "flex",
          alignItems: "center",
          marginLeft: count === null ? 0.24 * h : 0.26 * h,
          paddingLeft: count === null ? 0 : 0.24 * h,
          borderLeft: count === null ? "none" : `${0.03 * h}px solid rgba(243,238,232,0.16)`,
          height: 0.5 * h,
        }}
      >
        <span
          style={{
            display: "inline-flex",
            transform: `rotate(${star.rotate}deg) scale(${star.scale})`,
            color: starColour,
            filter: star.lit > 0 ? `drop-shadow(0 0 ${6 * u * star.lit}px rgba(255,176,138,${0.9 * star.lit}))` : undefined,
          }}
        >
          <StarGlyph size={0.38 * h} />
        </span>
        {count === null ? null : <Count count={count} roll={roll} h={h} />}
      </span>
    </div>
  );
}

/** The count, rolling up like an odometer as a star is added. */
function Count({ count, roll, h }: { count: number; roll: number; h: number }) {
  const line = 0.5 * h;
  const width = countWidth(count, h);
  const style = { height: line, lineHeight: `${line}px`, fontSize: 0.4 * h, fontWeight: 500 as const };
  return (
    <span style={{ marginLeft: 0.14 * h, width, height: line, overflow: "hidden", display: "inline-block" }}>
      <span style={{ display: "block", transform: `translateY(${-roll * line}px)` }}>
        <span style={{ ...style, display: "block", color: color.mute }}>{formatCount(count)}</span>
        <span style={{ ...style, display: "block", color: color.paper }}>{formatCount(count + 1)}</span>
      </span>
    </span>
  );
}

/** GitHub's mark (Octicons' mark-github), unaltered, as the website draws it. */
export function GitHubMark({ size }: { size: number }) {
  return (
    <svg viewBox="0 0 16 16" width={size} height={size} fill="currentColor" style={{ display: "block", flexShrink: 0 }}>
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}

export function StarGlyph({ size }: { size: number }) {
  return (
    <svg viewBox="0 0 16 16" width={size} height={size} fill="currentColor" style={{ display: "block" }}>
      <path d="M8 .25a.75.75 0 01.67.42l1.88 3.81 4.2.61a.75.75 0 01.42 1.28l-3.04 2.96.72 4.19a.75.75 0 01-1.09.79L8 12.33l-3.76 1.98a.75.75 0 01-1.09-.79l.72-4.19L.83 6.37a.75.75 0 01.42-1.28l4.2-.61L7.33.67A.75.75 0 018 .25z" />
    </svg>
  );
}

function mix(a: number[], b: number[], t: number): string {
  const k = Math.min(Math.max(t, 0), 1);
  const c = a.map((v, i) => v + (b[i] - v) * k);
  return `rgba(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])},${c[3].toFixed(3)})`;
}

function mixHex(a: string, b: string, t: number): string {
  const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16));
  const k = Math.min(Math.max(t, 0), 1);
  return `rgb(${pa.map((v, i) => Math.round(v + (pb[i] - v) * k)).join(",")})`;
}
