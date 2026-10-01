import { useId, type CSSProperties } from "react";
import { apply, combine, type Grade } from "../grade";

/** The illustration's daylight palette, before any grade. */
const base = {
  skyTop: "#3f7fd4",
  skyBottom: "#b8d5ef",
  sun: "#fff6dc",
  sunGlow: "#fff1c8",
  cloud: "#ffffff",
  hillFar: "#86a8b0",
  hillMid: "#5e8d4f",
  meadow: "#74b04a",
  meadowShade: "#4e8a35",
  path: "#c9b9a0",
  canopy: "#3e7a34",
  canopyHi: "#66a345",
  canopyShade: "#285624",
  trunk: "#4b3527",
  tree2: "#4a8a3b",
  tree2Shade: "#31652a",
};

/** The drawing is 1600 × 1000; it is cropped to fill whatever box it sits in. */
export const VIEW = { width: 1600, height: 1000 };
/** The big tree, for masks and overlays that point at it. */
export const TREE = { x: 600, y: 420 };
export const HORIZON = 560;

const canopy: [number, number, number][] = [
  [600, 425, 165],
  [475, 485, 112],
  [728, 475, 122],
  [555, 330, 105],
  [675, 335, 100],
];

/** Where a point of the drawing lands in a `width` × `height` box, as the slice crop places it. */
export function project(x: number, y: number, width: number, height: number) {
  const s = Math.max(width / VIEW.width, height / VIEW.height);
  return { x: x * s - (VIEW.width * s - width) / 2, y: y * s - (VIEW.height * s - height) / 2, scale: s };
}

type Props = {
  grade?: Grade;
  /** Extra grade for the sky only (a sky mask). */
  sky?: Grade;
  /** Extra grade for the big tree only (a subject mask). */
  tree?: Grade;
  /** The red mask overlay over the sky, drawn down to `edge` (0 to 1 of the horizon). */
  skyOverlay?: { edge: number; opacity: number };
  treeOverlay?: number;
  /** A detection line sweeping down the frame, 0 to 1; hidden outside that range. */
  scan?: number;
  style?: CSSProperties;
};

/** A flat, sunny landscape: sky, sun, two clouds, hills, a meadow, a path and a big tree. */
export function Landscape({ grade = {}, sky = {}, tree = {}, skyOverlay, treeOverlay = 0, scan = -1, style }: Props) {
  const id = useId().replace(/:/g, "");
  const c = (key: keyof typeof base, region?: Grade) => apply(base[key], region ? combine(grade, region) : grade);
  const halation = grade.halation ?? 0;
  const edge = skyOverlay ? 40 + skyOverlay.edge * (HORIZON - 40) : 0;

  return (
    <svg viewBox={`0 0 ${VIEW.width} ${VIEW.height}`} preserveAspectRatio="xMidYMid slice" style={{ width: "100%", height: "100%", display: "block", ...style }}>
      <defs>
        <linearGradient id={`sky-${id}`} x1="0" y1="0" x2="0" y2={HORIZON} gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor={c("skyTop", sky)} />
          <stop offset="1" stopColor={c("skyBottom", sky)} />
        </linearGradient>
        <radialGradient id={`sun-${id}`}>
          <stop offset="0" stopColor={c("sunGlow")} stopOpacity="0.9" />
          <stop offset="1" stopColor={c("sunGlow")} stopOpacity="0" />
        </radialGradient>
        <radialGradient id={`hal-${id}`}>
          <stop offset="0.3" stopColor="#ff3b22" stopOpacity="0" />
          <stop offset="0.5" stopColor="#ff3b22" stopOpacity={0.55 * halation} />
          <stop offset="1" stopColor="#ff3b22" stopOpacity="0" />
        </radialGradient>
        <linearGradient id={`mask-${id}`} x1="0" y1={edge - 90} x2="0" y2={edge + 30} gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#e0402e" stopOpacity="0.62" />
          <stop offset="1" stopColor="#e0402e" stopOpacity="0" />
        </linearGradient>
      </defs>

      <rect width={VIEW.width} height={VIEW.height} fill={`url(#sky-${id})`} />
      <circle cx="1080" cy="230" r="250" fill={`url(#sun-${id})`} />
      {halation ? <circle cx="1080" cy="230" r="170" fill={`url(#hal-${id})`} /> : null}
      <circle cx="1080" cy="230" r="64" fill={c("sun")} />
      <g fill={c("cloud", sky)} opacity="0.92">
        <rect x="200" y="160" width="300" height="56" rx="28" />
        <rect x="290" y="122" width="150" height="64" rx="32" />
        <rect x="1240" y="330" width="240" height="46" rx="23" />
        <rect x="1300" y="300" width="120" height="50" rx="25" />
      </g>

      {/* The sky mask sits behind the hills and trees, as a sky mask would. */}
      {skyOverlay && skyOverlay.opacity > 0 ? (
        <g opacity={skyOverlay.opacity}>
          <rect width={VIEW.width} height={edge + 30} fill={`url(#mask-${id})`} />
          <rect width={VIEW.width} height={Math.max(0, edge - 90)} fill="#e0402e" fillOpacity="0.62" />
        </g>
      ) : null}
      <path d="M0 565 C 200 505 380 520 560 548 C 760 578 900 505 1100 508 C 1300 512 1450 562 1600 545 L1600 1000 L0 1000Z" fill={c("hillFar")} />
      <path d="M0 645 C 260 602 480 612 700 632 C 950 657 1200 602 1600 622 L1600 1000 L0 1000Z" fill={c("hillMid")} />
      <path d="M0 700 C 400 680 900 692 1600 682 L1600 1000 L0 1000Z" fill={c("meadow")} />
      <ellipse cx="660" cy="726" rx="250" ry="26" fill={c("meadowShade")} />
      <path d="M 250 1000 C 330 900 420 822 520 762 C 600 716 700 702 762 699 L 792 703 C 722 714 642 737 582 777 C 482 842 430 922 410 1000 Z" fill={c("path")} />

      <g>
        <rect x="1252" y="560" width="16" height="96" rx="6" fill={c("trunk")} />
        <circle cx="1262" cy="540" r="82" fill={c("tree2Shade")} />
        <circle cx="1255" cy="525" r="76" fill={c("tree2")} />
        <circle cx="1235" cy="500" r="34" fill={c("canopyHi")} opacity="0.8" />
      </g>

      <g>
        <path d="M 584 724 L 590 520 L 614 520 L 622 724 Z" fill={c("trunk", tree)} />
        <g fill={c("canopyShade", tree)}>
          <circle cx="608" cy="445" r="172" />
          <circle cx="478" cy="505" r="118" />
          <circle cx="740" cy="495" r="126" />
        </g>
        <g fill={c("canopy", tree)}>
          {canopy.map(([x, y, r]) => (
            <circle key={`${x}-${y}`} cx={x} cy={y} r={r} />
          ))}
        </g>
        <g fill={c("canopyHi", tree)} opacity="0.9">
          <circle cx="545" cy="305" r="62" />
          <circle cx="452" cy="448" r="54" />
          <circle cx="648" cy="298" r="50" />
          <circle cx="742" cy="420" r="48" />
        </g>
      </g>

      {treeOverlay > 0 ? (
        <g fill="#e0402e" fillOpacity="0.62" opacity={treeOverlay}>
          <path d="M 584 724 L 590 520 L 614 520 L 622 724 Z" />
          <circle cx="608" cy="445" r="172" />
          <circle cx="478" cy="505" r="118" />
          <circle cx="740" cy="495" r="126" />
          {canopy.map(([x, y, r]) => (
            <circle key={`o-${x}-${y}`} cx={x} cy={y} r={r} />
          ))}
        </g>
      ) : null}
      {scan >= 0 && scan <= 1 ? (
        <g>
          <rect x="0" y={scan * VIEW.height - 120} width={VIEW.width} height="120" fill="#ffffff" opacity="0.08" />
          <rect x="0" y={scan * VIEW.height - 2} width={VIEW.width} height="4" fill="#ffffff" opacity="0.85" />
        </g>
      ) : null}
    </svg>
  );
}
