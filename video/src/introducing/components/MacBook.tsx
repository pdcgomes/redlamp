import type { ReactNode } from "react";

/**
 * A 16-inch MacBook Pro in Space Black, drawn in CSS 3D around the hinge's centre: the lid stands
 * up from it and tilts back, the base lies flat towards the viewer. Proportions come from the
 * real one (355.7 × 248.1 mm, a 3456 × 2234 display), in fractions of the lid's width. Lit from
 * above left, as the brand lights everything.
 */
const lidHeight = 0.6775;
const lidThickness = 0.011;
const baseDepth = 0.6975;
const baseThickness = 0.03;
/** The display, and where it sits in the lid. */
const display = { width: 0.972, aspect: 3456 / 2234, top: 0.0165 };

const metal = {
  top: "#2b2c2f",
  mid: "#212225",
  low: "#161719",
  edge: "#4a4b50",
  edgeLow: "#1c1d20",
};

type Props = {
  /** The lid's width in pixels. */
  width: number;
  /** Degrees the lid leans back from upright. */
  lean?: number;
  /** What's on the display; it fills the display's width and sits under the menu bar. */
  screen: ReactNode;
  /** The display's brightness, 0 (off) to 1. */
  power?: number;
  /** The camera's turn in degrees, so reflections slide as it moves. */
  turn?: number;
};

export function MacBook({ width: w, lean = 14, screen, power = 1, turn = 0 }: Props) {
  const lidH = lidHeight * w;
  const lidT = lidThickness * w;
  const depth = baseDepth * w;
  const thick = baseThickness * w;
  const screenW = display.width * w;
  const screenH = screenW / display.aspect;
  const inset = (w - screenW) / 2;
  const glare = 50 + turn * 1.6;
  return (
    <div style={{ position: "absolute", left: 0, top: 0, transformStyle: "preserve-3d" }}>
      <Floor width={w} depth={depth} thick={thick} />

      {/* The base: deck, front lip and sides. */}
      <div
        style={{
          position: "absolute",
          left: -w / 2,
          top: 0,
          width: w,
          height: depth,
          transformOrigin: "50% 0",
          transform: "rotateX(90deg)",
          borderRadius: `0 0 ${w * 0.022}px ${w * 0.022}px`,
          overflow: "hidden",
          background: `linear-gradient(170deg, ${metal.top} 0%, ${metal.mid} 55%, ${metal.low} 100%)`,
        }}
      >
        <Deck />
        <div style={{ position: "absolute", inset: 0, background: "linear-gradient(180deg, rgba(0,0,0,0.45), transparent 24%)" }} />
        <div
          style={{
            position: "absolute",
            inset: 0,
            background: "radial-gradient(70% 90% at 18% 100%, rgba(255,255,255,0.06), transparent 70%)",
          }}
        />
      </div>
      <div
        style={{
          position: "absolute",
          left: -w / 2,
          top: 0,
          width: w,
          height: thick,
          transform: `translateZ(${depth}px)`,
          borderRadius: `0 0 ${thick * 0.6}px ${thick * 0.6}px`,
          background: `linear-gradient(180deg, #6a6b70 0%, ${metal.edge} 7%, ${metal.mid} 22%, ${metal.low} 70%, #111213 100%)`,
        }}
      >
        <div
          style={{
            position: "absolute",
            left: "50%",
            top: 0,
            width: w * 0.12,
            height: thick * 0.32,
            transform: "translateX(-50%)",
            borderRadius: `0 0 ${thick}px ${thick}px`,
            background: "linear-gradient(180deg, #0d0d0e, #1f2022)",
          }}
        />
      </div>
      <Side x={-w / 2} depth={depth} thick={thick} face="left" />
      <Side x={w / 2} depth={depth} thick={thick} face="right" />

      {/* The lid, leaning back on the hinge. */}
      <div
        style={{
          position: "absolute",
          left: -w / 2,
          top: -lidH,
          width: w,
          height: lidH,
          transformStyle: "preserve-3d",
          transformOrigin: "50% 100%",
          transform: `rotateX(${lean}deg)`,
        }}
      >
        <div
          style={{
            position: "absolute",
            inset: 0,
            borderRadius: `${w * 0.024}px ${w * 0.024}px ${w * 0.01}px ${w * 0.01}px`,
            background: "#08080a",
            boxShadow: `inset 0 0 0 ${Math.max(1, w * 0.0015)}px #3a3b3e`,
            backfaceVisibility: "hidden",
            overflow: "hidden",
          }}
        >
          <div
            style={{
              position: "absolute",
              left: inset,
              top: display.top * w,
              width: screenW,
              height: screenH,
              borderRadius: `${w * 0.012}px ${w * 0.012}px 2px 2px`,
              overflow: "hidden",
              background: "#000",
            }}
          >
            <div style={{ position: "absolute", left: 0, bottom: 0, width: screenW, filter: power < 1 ? `brightness(${power})` : undefined }}>
              {screen}
            </div>
            {/* The notch, in the menu bar's strip. */}
            <div
              style={{
                position: "absolute",
                left: "50%",
                top: 0,
                width: w * 0.088,
                height: w * 0.0185,
                transform: "translateX(-50%)",
                background: "#000",
                borderRadius: `0 0 ${w * 0.008}px ${w * 0.008}px`,
              }}
            >
              <div
                style={{
                  position: "absolute",
                  left: "50%",
                  top: "45%",
                  width: w * 0.0045,
                  height: w * 0.0045,
                  transform: "translate(-50%, -50%)",
                  borderRadius: "50%",
                  background: "radial-gradient(circle at 35% 35%, #2a3140, #07080a 70%)",
                }}
              />
            </div>
            <div
              style={{
                position: "absolute",
                inset: 0,
                background: `linear-gradient(118deg, transparent ${glare - 24}%, rgba(255,255,255,0.095) ${glare - 5}%, rgba(255,255,255,0.03) ${glare + 6}%, transparent ${glare + 22}%)`,
              }}
            />
          </div>
        </div>
        <div
          style={{
            position: "absolute",
            inset: 0,
            transform: `translateZ(${-lidT}px) rotateY(180deg)`,
            borderRadius: `${w * 0.024}px ${w * 0.024}px ${w * 0.01}px ${w * 0.01}px`,
            background: `linear-gradient(160deg, ${metal.top}, ${metal.low})`,
            backfaceVisibility: "hidden",
          }}
        />
        <div
          style={{
            position: "absolute",
            left: w * 0.02,
            top: 0,
            width: w * 0.96,
            height: lidT,
            transformOrigin: "50% 0",
            transform: "rotateX(90deg)",
            background: `linear-gradient(90deg, ${metal.edgeLow}, ${metal.edge} 30%, ${metal.edge} 70%, ${metal.edgeLow})`,
          }}
        />
        {(["left", "right"] as const).map((face) => (
          <div
            key={face}
            style={{
              position: "absolute",
              left: face === "left" ? 0 : w - lidT,
              top: w * 0.02,
              width: lidT,
              height: lidH - w * 0.03,
              transformOrigin: face === "left" ? "0 50%" : "100% 50%",
              transform: `translateZ(${-lidT / 2}px) rotateY(${face === "left" ? -90 : 90}deg)`,
              background: `linear-gradient(180deg, ${metal.edge}, ${metal.edgeLow})`,
            }}
          />
        ))}
      </div>
    </div>
  );
}

function Side({ x, depth, thick, face }: { x: number; depth: number; thick: number; face: "left" | "right" }) {
  return (
    <div
      style={{
        position: "absolute",
        left: face === "left" ? x : x - depth,
        top: 0,
        width: depth,
        height: thick,
        transformOrigin: face === "left" ? "0 0" : "100% 0",
        transform: `rotateY(${face === "left" ? -90 : 90}deg)`,
        background: `linear-gradient(180deg, ${metal.edge} 0%, ${metal.mid} 25%, ${metal.low} 100%)`,
        opacity: face === "left" ? 1 : 0.85,
      }}
    />
  );
}

/** The surface it stands on: a soft pool of light and a contact shadow, lying under the base. */
function Floor({ width, depth, thick }: { width: number; depth: number; thick: number }) {
  return (
    <div
      style={{
        position: "absolute",
        left: -width * 1.1,
        top: thick + 1,
        width: width * 2.2,
        height: depth * 2.2,
        transformOrigin: "50% 0",
        transform: `translateZ(${-depth * 0.55}px) rotateX(90deg)`,
        background: `radial-gradient(34% 28% at 50% 48%, rgba(0,0,0,0.8), rgba(0,0,0,0.35) 60%, transparent 100%),
          radial-gradient(62% 46% at 50% 47%, rgba(255,255,255,0.06), rgba(255,255,255,0.02) 55%, transparent 100%)`,
      }}
    />
  );
}

/** The keyboard, trackpad and speaker grilles, in millimetres across the 355.7 × 248.1 deck. */
function Deck() {
  const keys: { x: number; y: number; w: number; h: number }[] = [];
  const left = 42;
  const right = 313.7;
  const gap = 2.3;
  const row = (y: number, h: number, widths: number[]) => {
    const total = widths.reduce((a, b) => a + b, 0);
    const scale = (right - left - gap * (widths.length - 1)) / total;
    let x = left;
    for (const unit of widths) {
      keys.push({ x, y, w: unit * scale, h });
      x += unit * scale + gap;
    }
  };
  row(12, 10.5, [1.5, ...Array(12).fill(1), 1]);
  row(25, 16.2, [...Array(13).fill(1), 1.55]);
  row(43.5, 16.2, [1.55, ...Array(13).fill(1)]);
  row(62, 16.2, [1.85, ...Array(11).fill(1), 1.85]);
  row(80.5, 16.2, [2.35, ...Array(10).fill(1), 2.35]);
  row(99, 16.2, [1, 1, 1, 1.25, 5.3, 1.25, 1, 3]);
  return (
    <svg viewBox="0 0 355.7 248.1" preserveAspectRatio="none" style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}>
      <defs>
        <pattern id="grille" width="1.45" height="1.45" patternUnits="userSpaceOnUse">
          <circle cx="0.72" cy="0.72" r="0.36" fill="#0b0b0c" />
        </pattern>
        <linearGradient id="key" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#141416" />
          <stop offset="1" stopColor="#0a0a0b" />
        </linearGradient>
        <linearGradient id="pad" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#ffffff" stopOpacity="0.06" />
          <stop offset="1" stopColor="#000000" stopOpacity="0.12" />
        </linearGradient>
      </defs>
      <rect x="38.5" y="9" width="278.7" height="110" rx="3" fill="#0e0e10" opacity="0.8" />
      {keys.map((k, i) => (
        <rect key={i} x={k.x} y={k.y} width={k.w} height={k.h} rx="1.6" fill="url(#key)" stroke="#26272a" strokeWidth="0.25" />
      ))}
      <rect x="9" y="12" width="25" height="103" fill="url(#grille)" />
      <rect x="321.7" y="12" width="25" height="103" fill="url(#grille)" />
      <rect x="97.9" y="131" width="160" height="101" rx="5" fill="#242528" stroke="#34353a" strokeWidth="0.45" />
      <rect x="97.9" y="131" width="160" height="101" rx="5" fill="url(#pad)" opacity="0.5" />
    </svg>
  );
}
