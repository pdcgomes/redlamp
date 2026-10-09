import { CURVE_WHITE } from "@/lib/tone";
import { Figure, sourceLink, textLink } from "../parts";

type Stage = { title: string; describes: string; written: string; text: string; door?: boolean };

const stages: Stage[] = [
  {
    title: "Develop",
    describes: "Scene",
    written: "Linear",
    text: "White balance, the camera's colour, Exposure (a multiply), halation and bloom (light added), the tone sliders, black and white points.",
  },
  {
    title: "Tone curve",
    describes: "Scene → display",
    written: "Log, for film looks",
    text: `Scene light to screen light, reaching white at ${CURVE_WHITE.toFixed(2)}, 4 stops over the grey card. A film look takes its place, reading a log encoding of the scene.`,
    door: true,
  },
  {
    title: "Colour",
    describes: "Display",
    written: "Linear",
    text: "Vibrance, Saturation, the Color Mixer, Point Color and Color Grading, in OKLab worked out from linear light.",
  },
  {
    title: "Finishing",
    describes: "Display",
    written: "sRGB curve",
    text: "Curves, vignette, grain, light leaks and the frame, on values written with the sRGB curve.",
  },
  {
    title: "Output",
    describes: "Display",
    written: "sRGB curve",
    text: "Fitted into sRGB or Display P3, which share the sRGB curve, for the screen, JPEG and TIFF.",
  },
];

function Band({ children, className = "", accent = false }: { children: string; className?: string; accent?: boolean }) {
  return (
    <div className={`rounded-lg bg-paper/[0.05] px-3 py-1.5 text-center text-[13px] ${accent ? "font-medium text-filament" : "text-mute"} ${className}`}>
      {children}
    </div>
  );
}

function Label({ children }: { children: string }) {
  return <p className="self-center text-[12px] text-dim">{children}</p>;
}

function StageText({ stage, index }: { stage: Stage; index: number }) {
  return (
    <>
      <p className="flex items-baseline gap-2">
        <span className="font-mono text-[12px] text-dim">{index + 1}</span>
        <span className="font-display text-[16px] text-paper">{stage.title}</span>
      </p>
      <p className="mt-2 text-[14px] leading-relaxed text-mute">{stage.text}</p>
    </>
  );
}

export function RenderOrder() {
  return (
    <Figure
      title="One render, in order"
      sub="Each stage marked by the light it describes and how its numbers are written."
      caption={
        <>
          Source: the order in{" "}
          <a className={textLink} href={sourceLink("packages/RedlampKernels/Sources/Shaders/Develop.metal")}>
            Develop.metal
          </a>
          , the Metal shader that renders every edit.
        </>
      }
    >
      <div className="hidden gap-2 md:grid md:grid-cols-[76px_repeat(5,minmax(0,1fr))]">
        <Label>Describes</Label>
        <Band>Scene</Band>
        <Band accent>Scene → display</Band>
        <Band className="col-span-3">Display</Band>
        <Label>Written as</Label>
        <Band>Linear</Band>
        <Band>Log, for film looks</Band>
        <Band>Linear</Band>
        <Band className="col-span-2">sRGB curve</Band>
        <Label>Stage</Label>
        {stages.map((stage, index) => (
          <div key={stage.title} className={`rounded-xl border bg-wall/40 p-4 ${stage.door ? "border-filament/40" : "border-hairline"}`}>
            <StageText stage={stage} index={index} />
          </div>
        ))}
      </div>
      <ol className="grid gap-3 md:hidden">
        {stages.map((stage, index) => (
          <li key={stage.title} className={`rounded-xl border bg-wall/40 p-4 ${stage.door ? "border-filament/40" : "border-hairline"}`}>
            <p className={`mb-2 text-[12px] ${stage.door ? "text-filament" : "text-dim"}`}>
              {stage.describes} · {stage.written}
            </p>
            <StageText stage={stage} index={index} />
          </li>
        ))}
      </ol>
    </Figure>
  );
}
