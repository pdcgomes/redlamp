import { continueRender, delayRender, Easing, staticFile } from "remotion";

/** The brand palette from docs/brand/README.md. */
export const color = {
  wall: "#0a0707",
  wallTop: "#261c1b",
  bakelite: "#221c1a",
  bakeliteHi: "#2c2421",
  steel: "#57504e",
  safelight: "#e0402e",
  safelightDeep: "#9a1c14",
  ruby: "#e0402e",
  rubyShadow: "#420a07",
  filament: "#ffb08a",
  amber: "#f6a04a",
  ring: "#d9d0cb",
  paper: "#f3eee8",
  ink: "#1a1414",
  mute: "#a89d98",
  dim: "#6f6561",
  hairline: "rgba(243,238,232,0.12)",
};

export const font = {
  family: "Inter, -apple-system, 'Helvetica Neue', sans-serif",
  display: { fontVariationSettings: '"opsz" 32', fontWeight: 600, letterSpacing: "-0.022em" } as const,
  mono: "'SF Mono', Menlo, monospace",
};

/** The ease used for every arrival: quick to start, long and soft to settle. */
export const easeOut = Easing.bezier(0.22, 1, 0.36, 1);
export const easeInOut = Easing.bezier(0.65, 0, 0.35, 1);

const fontHandle = delayRender("Loading Inter");
const inter = new FontFace("Inter", `url(${staticFile("fonts/InterVariable.woff2")}) format("woff2")`, {
  weight: "100 900",
});
inter
  .load()
  .then(() => {
    document.fonts.add(inter);
    continueRender(fontHandle);
  })
  .catch((error) => {
    console.error(error);
    continueRender(fontHandle);
  });
