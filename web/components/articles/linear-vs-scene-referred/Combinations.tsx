import { MIDDLE_GREY, level8, sceneLog, toneCurve } from "@/lib/tone";
import { sceneText } from "../format";

type Combination = {
  title: string;
  /** What the cell's row and column say, for phones, where the grid is one column. */
  axes: string;
  text: string;
  values: [string, string][];
  redlamp: string;
  elsewhere: string;
  edits?: boolean;
};

const card = MIDDLE_GREY;
const cloud = 2;

const combinations: Combination[] = [
  {
    title: "Scene-linear",
    axes: "Scene-referred, written linearly",
    text: "Proportional to the light in front of the camera, with no ceiling: a street lamp can read 20 while the grey card reads 0.18.",
    values: [
      ["Grey card", sceneText(card)],
      ["Sunlit cloud", sceneText(cloud)],
    ],
    redlamp: "White balance, Exposure, the tone sliders, halation and bloom, in linear Rec. 2020.",
    elsewhere: "A raw file's sensor values, OpenEXR, ACEScg.",
    edits: true,
  },
  {
    title: "Scene-referred, log-encoded",
    axes: "Scene-referred, written with a curve",
    text: "The same scene light on a log scale: every stop gets an equal share of the numbers, so a wide range fits between 0 and 1.",
    values: [
      ["Grey card", sceneLog(card).toFixed(3)],
      ["Sunlit cloud", sceneLog(cloud).toFixed(3)],
    ],
    redlamp: "Film looks read their tables from it, over −10 to +6.5 stops around the grey card.",
    elsewhere: "Camera log video (S-Log3, LogC), ACEScct.",
  },
  {
    title: "Display-linear",
    axes: "Display-referred, written linearly",
    text: "Proportional to the light the screen gives off. 1.0 is the screen's white and nothing goes above it: the tone curve has already fitted the scene in.",
    values: [
      ["Grey card", toneCurve(card).toFixed(3)],
      ["Sunlit cloud", toneCurve(cloud).toFixed(3)],
    ],
    redlamp: "Vibrance, Saturation, the Color Mixer, Point Color and Color Grading, in OKLab worked out from this light.",
    elsewhere: "A TIFF of a finished render saved with linear numbers.",
  },
  {
    title: "Display-encoded",
    axes: "Display-referred, written with a curve",
    text: "What JPEGs, PNGs and the screen's signal carry: screen light written with the sRGB curve, which gives the darks more of the 256 levels.",
    values: [
      ["Grey card", `${level8(toneCurve(card))} of 255`],
      ["Sunlit cloud", `${level8(toneCurve(cloud))} of 255`],
    ],
    redlamp: "Curves, vignette and grain; then the export and the screen.",
    elsewhere: "Every JPEG. sRGB and Display P3 share this curve.",
  },
];

function Axis({ title, sub, centred = false }: { title: string; sub: string; centred?: boolean }) {
  return (
    <div className={`hidden px-1 sm:block ${centred ? "self-end text-center" : "self-center"}`}>
      <p className="text-[14px] font-semibold text-paper">{title}</p>
      <p className="mt-0.5 text-[13px] leading-snug text-dim">{sub}</p>
    </div>
  );
}

function Cell({ combination }: { combination: Combination }) {
  const { title, axes, text, values, redlamp, elsewhere, edits } = combination;
  return (
    <div className={`surface flex min-w-0 flex-col gap-4 p-5 ${edits ? "border-filament/40" : ""}`}>
      <div>
        <p className="mb-1 text-[12px] text-dim sm:hidden">{axes}</p>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p className="font-display text-[17px] text-paper">{title}</p>
          {edits ? (
            <span className="rounded-pill border border-filament/40 px-2.5 py-0.5 text-[12px] text-filament">Redlamp edits here</span>
          ) : null}
        </div>
      </div>
      <p className="text-[14px] leading-relaxed text-mute">{text}</p>
      <div className="flex flex-wrap gap-x-7 gap-y-2">
        {values.map(([name, value]) => (
          <div key={name}>
            <p className="text-[12px] text-dim">{name}</p>
            <p className="font-mono text-[17px] text-paper tabular-nums">{value}</p>
          </div>
        ))}
      </div>
      <div>
        <p className="text-[12px] text-dim">In Redlamp</p>
        <p className="mt-0.5 text-[14px] leading-relaxed text-ring">{redlamp}</p>
      </div>
      <div>
        <p className="text-[12px] text-dim">Elsewhere</p>
        <p className="mt-0.5 text-[14px] leading-relaxed text-mute">{elsewhere}</p>
      </div>
    </div>
  );
}

export function Combinations() {
  return (
    <div className="grid gap-3 sm:grid-cols-[104px_minmax(0,1fr)_minmax(0,1fr)]">
      <div className="hidden sm:block" />
      <p className="eyebrow hidden pb-1 text-center sm:col-span-2 sm:block">How the numbers are written →</p>
      <p className="eyebrow hidden self-end px-1 sm:block">Whose light ↓</p>
      <Axis title="Linear" sub="Twice the light, twice the number" centred />
      <Axis title="Non-linear" sub="A curve: sRGB, gamma or log" centred />
      <Axis title="Scene-referred" sub="The light in front of the camera; no ceiling" />
      <Cell combination={combinations[0]} />
      <Cell combination={combinations[1]} />
      <Axis title="Display-referred" sub="The light the screen gives off; stops at white" />
      <Cell combination={combinations[2]} />
      <Cell combination={combinations[3]} />
    </div>
  );
}
