import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { Words } from "../components/Kinetic";
import { Landscape } from "../components/Landscape";
import { glass } from "../components/Media";
import { Stage } from "../components/Stage";
import { Chip, Cursor, Keycap, Skel, TrafficLights } from "../components/UI";
import { type Grade, looks } from "../grade";
import { type Layout, useLayout, useSprings } from "../layout";
import { color, font } from "../theme";

type Slider = { name: string; min: number; max: number; base: number; to?: number; decimals?: number; gradient?: string; step?: number };

const basic: Slider[] = [
  { name: "Temp", min: 2000, max: 12000, base: 5200, to: 6400, step: 50, gradient: "linear-gradient(90deg,#4f7fd1,#e8c25a)" },
  { name: "Tint", min: -150, max: 150, base: 4, gradient: "linear-gradient(90deg,#4fb06a,#c65bc9)" },
  { name: "Exposure", min: -5, max: 5, base: 0, to: 0.85, decimals: 2 },
  { name: "Contrast", min: -100, max: 100, base: 0, to: 24 },
  { name: "Highlights", min: -100, max: 100, base: 0, to: -68 },
  { name: "Shadows", min: -100, max: 100, base: 0, to: 52 },
  { name: "Whites", min: -100, max: 100, base: 0 },
  { name: "Blacks", min: -100, max: 100, base: 0, to: -22 },
];
const presence: Slider[] = [
  { name: "Texture", min: -100, max: 100, base: 0 },
  { name: "Clarity", min: -100, max: 100, base: 0 },
  { name: "Dehaze", min: -100, max: 100, base: 0 },
];

/** One confident move after another, a beat apart: [slider row, frame]. */
const moves: [number, number][] = [
  [2, 26],
  [4, 40],
  [5, 54],
  [3, 68],
  [0, 82],
  [7, 96],
];
const TOGGLE = [116, 132];

const flat: Grade = { exposure: -0.55, contrast: -0.3, saturation: -0.4, fade: 0.6 };

/** The edit as a grade on the illustration, from the current slider values. */
function gradeFrom(v: number[]): Grade {
  const [temp, , ev, contrast, highlights, shadows, , blacks] = v;
  return {
    exposure: -0.55 + (ev / 0.85) * 0.62,
    contrast: -0.3 + (contrast / 24) * 0.4 + (-blacks / 22) * 0.08,
    saturation: -0.4 + (contrast / 24) * 0.25 + (shadows / 52) * 0.15 + ((temp - 5200) / 1200) * 0.12,
    fade: 0.6 * (1 - -blacks / 22),
    highlights: (-highlights / 68) * 0.9,
    shadows: (shadows / 52) * 0.8,
    warmth: ((temp - 5200) / 1200) * 0.4,
  };
}

function geometry(l: Layout) {
  const g = l.wide
    ? { x: 160, y: 250, w: 1600, h: 780, sidebar: 220, panel: 450, film: 92, row: 42, label: 116, value: 64, text: 17 }
    : l.tall
      ? { x: 40, y: 440, w: 1000, h: 1360, sidebar: 0, panel: 0, film: 96, row: 50, label: 150, value: 84, text: 23 }
      : { x: 40, y: 200, w: 1000, h: 850, sidebar: 0, panel: 410, film: 78, row: 42, label: 112, value: 60, text: 17 };
  const stacked = l.tall;
  const pad = 22;
  const canvas = stacked
    ? { x: 14, y: 52, w: g.w - 28, h: 560 }
    : { x: g.sidebar + 14, y: 52, w: g.w - g.sidebar - g.panel - 28, h: g.h - 52 - g.film - 24 };
  const strip = { x: canvas.x, y: canvas.y + canvas.h + 10, w: canvas.w, h: g.film };
  const panel = stacked
    ? { x: 0, y: strip.y + strip.h + 6, w: g.w, h: g.h - (strip.y + strip.h + 6) }
    : { x: g.w - g.panel, y: 40, w: g.panel, h: g.h - 40 };
  const hist = stacked ? 110 : l.square ? 96 : 120;
  const rowsTop = pad + hist + 14 + 40;
  const trackX = pad + g.label + 12;
  const trackW = panel.w - pad * 2 - g.label - g.value - 24;
  return { ...g, stacked, pad, canvas, strip, panel, hist, rowsTop, trackX, trackW };
}

function format(v: number, s: Slider) {
  const step = s.step ?? 10 ** -(s.decimals ?? 0);
  const rounded = Math.round(v / step) * step;
  const fixed = rounded.toFixed(s.decimals ?? 0);
  return rounded > 0 && s.min < 0 ? `+${fixed}` : fixed;
}

function Histogram({ w, h, grade }: { w: number; h: number; grade: Grade }) {
  const shift = (grade.exposure ?? 0) * 0.22;
  const spread = 1 + (grade.contrast ?? 0) * 0.9;
  const warm = (grade.warmth ?? 0) * 0.08;
  const recover = (grade.highlights ?? 0) * 0.08;
  const lift = (grade.shadows ?? 0) * 0.05;
  const channel = (center: number, sky: number) => {
    const pts: string[] = [];
    for (let i = 0; i <= 64; i++) {
      const x = i / 64;
      const g = (c: number, s: number, a: number) => a * Math.exp(-(((x - c) / s) ** 2));
      const y = g(0.5 + (center - 0.5) * spread + shift + lift, 0.13 * spread, 0.9) + g(sky + shift - recover, 0.07, 0.6) + g(0.12 + lift, 0.06, 0.3);
      pts.push(`${(x * w).toFixed(1)},${(h - Math.min(1, y) * (h - 6)).toFixed(1)}`);
    }
    return `M0,${h} L${pts.join(" L")} L${w},${h} Z`;
  };
  return (
    <svg width={w} height={h} style={{ display: "block", borderRadius: 10, background: "rgba(0,0,0,0.25)" }}>
      <g style={{ mixBlendMode: "screen" }}>
        <path d={channel(0.5 + warm, 0.78 + warm)} fill="#e0402e" fillOpacity="0.45" />
        <path d={channel(0.48, 0.8)} fill="#3fae5a" fillOpacity="0.45" />
        <path d={channel(0.45 - warm, 0.86 - warm)} fill="#4f7fd1" fillOpacity="0.5" />
      </g>
    </svg>
  );
}

/** The editor builds itself, then a power user makes six decisive moves and checks before / after. */
export function Editor() {
  const frame = useCurrentFrame();
  const s = useSprings();
  const layout = useLayout();
  const g = geometry(layout);
  const rows = g.stacked ? basic : [...basic, ...presence];

  const values = basic.map((slider, i) => {
    const move = moves.find(([row]) => row === i);
    if (!move || slider.to === undefined) return slider.base;
    const at = move[1];
    const anticipation = interpolate(frame, [at, at + 2, at + 4], [0, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
    const p = s(at + 2, "drag") - 0.06 * anticipation;
    return slider.base + (slider.to - slider.base) * p;
  });
  const norm = (i: number, v: number) => (v - rows[i].min) / (rows[i].max - rows[i].min);
  const thumb = (i: number, v: number) => ({
    x: g.panel.x + g.trackX + norm(i, v) * g.trackW,
    y: g.panel.y + g.rowsTop + i * g.row + g.row / 2,
  });

  const toggled = frame >= TOGGLE[0] && frame < TOGGLE[1];
  const after = gradeFrom(values);
  const shown = toggled ? flat : after;

  // The cursor travels to each thumb a few frames before it grabs it, then drags with it.
  let cursor = { x: g.w + 80, y: g.h + 60 };
  let pressed = 0;
  let active = -1;
  for (let k = 0; k < moves.length; k++) {
    const [row, at] = moves[k];
    if (frame < at - 8) break;
    const from = k === 0 ? cursor : thumb(moves[k - 1][0], basic[moves[k - 1][0]].to ?? 0);
    const to = thumb(row, basic[row].base);
    const travel = s(at - 8, "snap");
    cursor = frame < at ? { x: from.x + (to.x - from.x) * travel, y: from.y + (to.y - from.y) * travel } : thumb(row, values[row]);
    pressed = interpolate(frame, [at - 1, at + 1, at + 11, at + 13], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
    active = row;
  }
  if (frame >= moves[moves.length - 1][1] + 14) {
    const last = thumb(moves[moves.length - 1][0], values[moves[moves.length - 1][0]]);
    const away = s(moves[moves.length - 1][1] + 14, "snap");
    cursor = { x: last.x + away * 60, y: last.y + away * 40 };
    active = -1;
  }

  const win = s(0, "pop");
  const keyIn = s(TOGGLE[0] - 6, "pop");
  const press = (at: number) => interpolate(frame, [at - 2, at, at + 4], [0, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const keyPress = Math.max(press(TOGGLE[0]), press(TOGGLE[1]));
  const keyOut = s(TOGGLE[1] + 8, "snap");
  const labelPop = s(toggled ? TOGGLE[0] : TOGGLE[1], "pop");

  const strip = Array.from({ length: 7 }, (_, i) => i);
  const stripLooks = [null, "portra-400", "tri-x-400", "velvia-50", "cinestill-800t", "ektar-100", "vision3-500t-2383"] as const;
  const thumbH = g.strip.h - 16;
  const thumbW = Math.min(thumbH * 1.5, (g.strip.w - 16 - 6 * 10) / 7);

  return (
    <Stage glowX={0.5} glowY={0.08} pulses={moves.map(([, at]) => at + 2)}>
      <AbsoluteFill style={{ alignItems: "center", paddingTop: layout.wide ? 70 : layout.tall ? 150 : 50 }}>
        <Words
          text={layout.wide ? "The panels, sliders and shortcuts you know." : "The panels, sliders\nand shortcuts you know."}
          size={layout.wide ? 76 : layout.tall ? 80 : 58}
          stagger={2}
          start={2}
        />
      </AbsoluteFill>

      <div
        style={{
          position: "absolute",
          left: g.x,
          top: g.y,
          width: g.w,
          height: g.h,
          ...glass,
          borderRadius: 26,
          overflow: "hidden",
          transformOrigin: "50% 100%",
          transform: `translateY(${(1 - win) * 260}px) scale(${0.9 + 0.1 * win})`,
          opacity: Math.min(1, win * 3),
        }}
      >
        <div style={{ position: "absolute", left: 20, top: 14 }}>
          <TrafficLights />
        </div>
        <div style={{ position: "absolute", left: g.w / 2 - 90, top: 16 }}>
          <Skel w={180} h={10} />
        </div>

        {g.sidebar ? (
          <div style={{ position: "absolute", left: 16, top: 52, width: g.sidebar - 16, opacity: s(4, "snap") }}>
            <div style={{ width: g.sidebar - 28, height: 112, borderRadius: 10, overflow: "hidden" }}>
              <Landscape grade={shown} />
            </div>
            {[0.7, 0.5, 0.82, 0.6, 0.44, 0.74, 0.56, 0.66, 0.4].map((w, i) => (
              <div key={i} style={{ display: "flex", gap: 10, alignItems: "center", marginTop: i === 0 ? 22 : 16, opacity: s(6 + i, "snap") }}>
                <Skel w={14} h={14} style={{ borderRadius: 4 }} />
                <Skel w={(g.sidebar - 60) * w} />
              </div>
            ))}
          </div>
        ) : null}

        <div style={{ position: "absolute", left: g.canvas.x, top: g.canvas.y, width: g.canvas.w, height: g.canvas.h, borderRadius: 12, overflow: "hidden", background: "#120d0c" }}>
          <Landscape grade={shown} />
          <div style={{ position: "absolute", left: 18, top: 18, transform: `scale(${0.6 + 0.4 * labelPop})`, transformOrigin: "0 0", opacity: frame >= TOGGLE[0] ? 1 - keyOut : 0 }}>
            <Chip active={1} size={g.text + 2}>
              {toggled ? "Before" : "After"}
            </Chip>
          </div>
        </div>

        <div style={{ position: "absolute", left: g.strip.x, top: g.strip.y, width: g.strip.w, height: g.strip.h, display: "flex", gap: 10, alignItems: "center", padding: 8 }}>
          {strip.map((i) => {
            const look = stripLooks[i];
            const pop = s(5 + i * 1.5, "pop");
            return (
              <div
                key={i}
                style={{
                  width: thumbW,
                  height: thumbH,
                  borderRadius: 8,
                  overflow: "hidden",
                  flexShrink: 0,
                  outline: i === 0 ? `3px solid ${color.ring}` : "none",
                  outlineOffset: 2,
                  transform: `translateY(${(1 - pop) * 40}px)`,
                  opacity: Math.min(1, pop * 2),
                }}
              >
                <Landscape grade={look ? looks[look].grade : shown} />
              </div>
            );
          })}
        </div>

        <div
          style={{
            position: "absolute",
            left: g.panel.x,
            top: g.panel.y,
            width: g.panel.w,
            height: g.panel.h,
            borderLeft: g.stacked ? "none" : `1px solid ${color.hairline}`,
            borderTop: g.stacked ? `1px solid ${color.hairline}` : "none",
            fontFamily: font.family,
          }}
        >
          <div style={{ position: "absolute", left: g.pad, top: g.pad, opacity: s(6, "snap") }}>
            <Histogram w={g.panel.w - g.pad * 2} h={g.hist} grade={shown} />
          </div>
          <div style={{ position: "absolute", left: g.pad, right: g.pad, top: g.pad + g.hist + 14, height: 40, display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            <span style={{ fontSize: g.text + 4, fontWeight: 600, color: color.paper }}>Basic</span>
            <Skel w={110} h={g.text * 0.9} />
          </div>
          {rows.map((slider, i) => {
            const v = i < basic.length ? values[i] : slider.base;
            const t = norm(i, v);
            const inT = s(8 + i * 1.5, "pop");
            const isActive = i === active;
            return (
              <div
                key={slider.name}
                style={{
                  position: "absolute",
                  left: 8,
                  right: 8,
                  top: g.rowsTop + i * g.row,
                  height: g.row,
                  borderRadius: 10,
                  background: isActive ? "rgba(243,238,232,0.07)" : "transparent",
                  opacity: Math.min(1, inT * 2),
                  transform: `translateX(${(1 - inT) * 50}px)`,
                }}
              >
                <span style={{ position: "absolute", left: g.pad - 8, top: 0, lineHeight: `${g.row}px`, fontSize: g.text, color: isActive ? color.paper : color.mute }}>{slider.name}</span>
                <div style={{ position: "absolute", left: g.trackX - 8, width: g.trackW, top: g.row / 2 - 2, height: 4, borderRadius: 2, background: slider.gradient ?? "rgba(243,238,232,0.16)" }}>
                  <div
                    style={{
                      position: "absolute",
                      left: `calc(${t * 100}% - 10px)`,
                      top: -8,
                      width: 20,
                      height: 20,
                      borderRadius: 10,
                      background: "#ece6e1",
                      boxShadow: "0 2px 6px rgba(0,0,0,0.5)",
                      transform: `scale(${isActive ? 1 + 0.25 * pressed : 1})`,
                    }}
                  />
                </div>
                <span
                  style={{
                    position: "absolute",
                    right: g.pad - 8,
                    top: 0,
                    lineHeight: `${g.row}px`,
                    fontSize: g.text,
                    color: color.paper,
                    fontVariantNumeric: "tabular-nums",
                    fontWeight: isActive ? 600 : 400,
                  }}
                >
                  {format(v, slider)}
                </span>
              </div>
            );
          })}
        </div>

        <Cursor x={cursor.x} y={cursor.y} size={g.text * 1.7} pressed={pressed} />
      </div>

      <div
        style={{
          position: "absolute",
          left: g.x + g.canvas.x + g.canvas.w - (layout.tall ? 150 : 130),
          top: g.y + g.canvas.y + 24,
          transform: `scale(${keyIn * (1 - keyOut)})`,
          opacity: keyIn > 0.01 ? 1 : 0,
        }}
      >
        <Keycap size={layout.tall ? 110 : 92} press={keyPress}>
          \
        </Keycap>
      </div>
    </Stage>
  );
}
