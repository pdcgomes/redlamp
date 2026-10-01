import type { CSSProperties } from "react";
import { color, font } from "../../theme";
import { margin, type } from "../canvas";
import { floating } from "../components/Card";
import { Headline } from "../components/Headline";
import { Shot } from "../components/Shot";
import { StillFrame } from "../components/StillFrame";
import { cameraRecipe, regions } from "../regions";

/** The card the bundled Chrome Street recipe is built from (RedlampRecipes' StarterPack). */
const card: [string, string][] = [
  ["Film simulation", "Classic Chrome"],
  ["Dynamic range", "DR400"],
  ["Highlight", "−1"],
  ["Shadow", "+1"],
  ["Color", "−2"],
  ["Color Chrome effect", "Strong"],
  ["Color Chrome FX Blue", "Weak"],
  ["White balance", "Auto, R+2 B−4"],
  ["Grain", "Weak, small"],
];

/** ΔE2000 to the camera's own JPEGs on photos the fit never saw, against Redlamp Color (README, Measured film looks). */
const measured = [
  { look: "Standard", like: "Provia", ours: 3.26, baseline: 5.38 },
  { look: "Vivid Slide", like: "Velvia", ours: 3.39, baseline: 4.45 },
  { look: "Chrome", like: "Classic Chrome", ours: 4.61, baseline: 5.72 },
];

/** Fujifilm recipes as photographers write them, and the measured looks they land on. */
export function Fujifilm() {
  return (
    <StillFrame index={4}>
      <Headline
        title="Fujifilm recipes, setting for setting."
        sub="Dynamic Range, Color Chrome and WB shift, on looks measured against Fujifilm's own JPEGs."
        size={80}
        style={{ position: "absolute", left: margin, top: 80, width: 700 }}
      />
      <div style={{ position: "absolute", left: 850, top: 72 }}>
        <Shot name="fujifilm" region={regions.photo32} width={494} radius={20} style={{ boxShadow: floating }} />
      </div>
      <RecipeCard style={{ position: "absolute", left: margin + 6, top: 478 }} />
      <div style={{ position: "absolute", left: 548, top: 528 }}>
        <Shot name="fujifilm-effects" region={cameraRecipe} width={404} radius={18} style={{ boxShadow: floating }} />
      </div>
      <DeltaE style={{ position: "absolute", left: 1000, top: 478, width: 344 }} />
      <div
        style={{
          position: "absolute",
          left: 548,
          top: 742,
          width: 404,
          fontFamily: font.family,
          fontSize: type.small - 2,
          lineHeight: 1.35,
          color: color.dim,
        }}
      >
        Fujifilm and its film simulation names are trademarks of FUJIFILM Corporation. Redlamp isn't affiliated with it.
      </div>
    </StillFrame>
  );
}

function RecipeCard({ style }: { style: CSSProperties }) {
  return (
    <div
      style={{
        width: 400,
        padding: "20px 24px 16px",
        borderRadius: 14,
        background: color.paper,
        color: color.ink,
        fontFamily: font.family,
        boxShadow: floating,
        transform: "rotate(-2deg)",
        ...style,
      }}
    >
      <div style={{ ...font.display, fontSize: 28, marginBottom: 10 }}>Chrome Street</div>
      {card.map(([setting, value]) => (
        <div
          key={setting}
          style={{
            display: "flex",
            justifyContent: "space-between",
            gap: 16,
            fontSize: 19,
            lineHeight: 1.5,
            borderTop: "1px solid rgba(26,20,20,0.12)",
          }}
        >
          <span style={{ color: "rgba(26,20,20,0.62)" }}>{setting}</span>
          <span style={{ fontWeight: 600 }}>{value}</span>
        </div>
      ))}
    </div>
  );
}

function DeltaE({ style }: { style: CSSProperties }) {
  const max = 6;
  return (
    <div style={{ fontFamily: font.family, color: color.paper, ...style }}>
      <div style={{ fontSize: 24, color: color.mute, marginBottom: 18, lineHeight: 1.3 }}>
        ΔE to Fujifilm's own JPEG.
        <br />
        Lower is closer.
      </div>
      {measured.map(({ look, like, ours, baseline }) => (
        <div key={look} style={{ marginBottom: 16 }}>
          <div style={{ fontSize: 24, marginBottom: 6, whiteSpace: "nowrap" }}>
            {look} <span style={{ color: color.mute }}>· {like}</span>
          </div>
          <Bar value={ours} max={max} tone={color.paper} label={ours.toFixed(2)} />
          <Bar value={baseline} max={max} tone={color.steel} label={`${baseline.toFixed(2)} default look`} />
        </div>
      ))}
    </div>
  );
}

function Bar({ value, max, tone, label }: { value: number; max: number; tone: string; label: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12, height: 22, marginBottom: 2 }}>
      <div style={{ width: `${(value / max) * 62}%`, height: 10, borderRadius: 5, background: tone }} />
      <span style={{ fontSize: 18, color: color.mute, whiteSpace: "nowrap" }}>{label}</span>
    </div>
  );
}
