"use client";

import { type ReactNode, useState } from "react";
import { CURVE_WHITE, MIDDLE_GREY, clamp, lstar, stopsFromGrey, toneCurve } from "@/lib/tone";
import { lightnessPhrase, lightnessText, sceneText, signed } from "../format";
import { Chip, Slider, Toggle, useWidth } from "../interactive";
import { Figure, LegendLine, Num, Patch, ink } from "../parts";

const scene = [
  { name: "Deep shadow", value: 0.008 },
  { name: "Dark coat", value: 0.04 },
  { name: "Grey card", value: 0.18 },
  { name: "White paper", value: 0.8 },
  { name: "Sunlit cloud", value: 2 },
  { name: "Street lamp", value: 20 },
];

type Mode = "after" | "none";

const whiteStop = stopsFromGrey(1);
const curveWhiteStop = stopsFromGrey(CURVE_WHITE);

function ToneChart({ ev, mode }: { ev: number; mode: Mode }) {
  const [ref, width] = useWidth<HTMLDivElement>(760);
  const narrow = width < 560;
  const height = narrow ? 300 : 322;
  const left = 44;
  const right = width - 10;
  const top = 30;
  const bottom = height - (narrow ? 88 : 74);
  const first = -8;
  const last = 8;
  const gain = 2 ** ev;
  const xs = (stops: number) => left + ((clamp(stops, first, last) - first) / (last - first)) * (right - left);
  const yl = (l: number) => bottom - (clamp(l, 0, 100) / 100) * (bottom - top);
  const sceneAt = (stops: number) => MIDDLE_GREY * 2 ** stops;
  const main = (stops: number) => lstar(toneCurve(sceneAt(stops)));
  const compare = (stops: number) =>
    mode === "after" ? lstar(Math.min(toneCurve(sceneAt(stops) / gain) * gain, 1)) : lstar(Math.min(sceneAt(stops), 1));
  const path = (f: (stops: number) => number) =>
    Array.from({ length: 321 }, (_, i) => {
      const stops = first + ((last - first) * i) / 320;
      return `${i === 0 ? "M" : "L"}${xs(stops).toFixed(1)},${yl(f(stops)).toFixed(1)}`;
    }).join(" ");
  const ticks = narrow ? [-8, -4, 0, 4, 8] : [-8, -6, -4, -2, 0, 2, 4, 6, 8];
  const labelRows = narrow ? 3 : 2;
  const markers = [
    { stops: 0, label: "0.18" },
    { stops: whiteStop, label: "1.0" },
    { stops: curveWhiteStop, label: CURVE_WHITE.toFixed(2) },
  ];
  const objects = scene.map((object, index) => {
    const stops = stopsFromGrey(object.value * gain);
    return { ...object, index, stops, inside: stops >= first && stops <= last, main: main(stops), compare: compare(stops) };
  });
  return (
    <div ref={ref}>
      <svg
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label="Displayed lightness against scene light, for Redlamp's tone curve and the comparison, with the scene's objects marked"
        className="block h-auto w-full"
      >
        <rect x={xs(whiteStop)} y={top} width={right - xs(whiteStop)} height={bottom - top} fill={ink.shade} />
        <text x={right - 6} y={bottom - 8} textAnchor="end" fontSize="11" fill={ink.tick}>
          {narrow ? "Above 1.0" : "Above 1.0: scene-referred only"}
        </text>
        {[0, 25, 50, 75, 100].map((l) => (
          <g key={l}>
            <line x1={left} x2={right} y1={yl(l)} y2={yl(l)} stroke={ink.grid} />
            <text x={left - 8} y={yl(l) + 4} textAnchor="end" fontSize="11" fill={ink.tick}>
              {l}
            </text>
          </g>
        ))}
        {ticks.map((stops) => (
          <text key={stops} x={xs(stops)} y={bottom + 16} textAnchor="middle" fontSize="11" fill={ink.tick}>
            {stops === 0 ? "0" : signed(stops, 0)}
          </text>
        ))}
        <text x={left} y={top - 12} fontSize="11" fill={ink.tick}>
          Scene value
        </text>
        {markers.map((marker) => (
          <g key={marker.label}>
            <line x1={xs(marker.stops)} x2={xs(marker.stops)} y1={top - 6} y2={bottom} stroke={ink.marker} strokeDasharray="2 3" />
            <text x={xs(marker.stops)} y={top - 12} textAnchor="middle" fontSize="11" fill={ink.label}>
              {marker.label}
            </text>
          </g>
        ))}
        <path d={path(compare)} fill="none" stroke={ink.compare} strokeWidth="1.75" strokeDasharray="5 4" />
        <path d={path(main)} fill="none" stroke={ink.accent} strokeWidth="2.25" />
        {objects
          .filter((object) => object.inside)
          .map((object) => (
            <g key={object.name}>
              <line
                x1={xs(object.stops)}
                x2={xs(object.stops)}
                y1={Math.min(yl(object.main), yl(object.compare))}
                y2={bottom}
                stroke={ink.marker}
                strokeDasharray="1 3"
              />
              <circle cx={xs(object.stops)} cy={yl(object.compare)} r="5" fill={ink.surface} stroke={ink.compare} strokeWidth="1.5" />
              <circle cx={xs(object.stops)} cy={yl(object.main)} r="3.5" fill={ink.accent} />
            </g>
          ))}
        {objects.map((object) => {
          const before = object.stops < first;
          const anchor = object.inside ? "middle" : before ? "start" : "end";
          const label = object.inside ? object.name : before ? `← ${object.name}` : `${object.name} →`;
          const half = label.length * 3.2;
          return (
            <text
              key={object.name}
              x={object.inside ? clamp(xs(object.stops), left + half, right - half) : before ? left : right}
              y={bottom + 34 + (object.index % labelRows) * 14}
              textAnchor={anchor}
              fontSize="11"
              fill={ink.label}
            >
              {label}
            </text>
          );
        })}
        <text x={(left + right) / 2} y={height - 6} textAnchor="middle" fontSize="11" fill={ink.label}>
          Scene light after Exposure, in stops from the grey card
        </text>
        <text transform={`translate(12 ${(top + bottom) / 2}) rotate(-90)`} textAnchor="middle" fontSize="11" fill={ink.label}>
          Displayed lightness, L*
        </text>
      </svg>
    </div>
  );
}

function RowLabel({ title, sub }: { title: string; sub: string }) {
  return (
    <div className="self-center">
      <p className="text-[13px] font-medium text-paper">{title}</p>
      <p className="text-[12px] leading-snug text-dim">{sub}</p>
    </div>
  );
}

function Six({ children }: { children: ReactNode }) {
  return <div className="grid grid-cols-6 gap-2">{children}</div>;
}

function PatchCell({ light }: { light: number }) {
  return (
    <div>
      <Patch light={light} className="h-10" />
      <p className="mt-1 text-center font-mono text-[11px] text-dim tabular-nums">{lightnessText(light)}</p>
    </div>
  );
}

export function ExposurePlayground() {
  const [ev, setEv] = useState(0);
  const [mode, setMode] = useState<Mode>("after");
  const gain = 2 ** ev;
  const rows = scene.map((object) => ({
    ...object,
    scene: object.value * gain,
    first: toneCurve(object.value * gain),
    compare: mode === "after" ? Math.min(toneCurve(object.value) * gain, 1) : Math.min(object.value * gain, 1),
  }));
  const explanation =
    mode === "after" ? (
      <>
        Try −2: with Exposure first, the cloud comes back ({lightnessPhrase(toneCurve(2 * 0.25))}) and the lamp stays white. With Exposure after the
        curve, both had already been written as white, or within a hair of it, so they darken to the same flat grey (
        {lightnessPhrase(Math.min(toneCurve(2) * 0.25, 1))} and {lightnessPhrase(Math.min(toneCurve(20) * 0.25, 1))}): the curve threw away the
        difference between 2 and 20. Try +2: with Exposure first, the grey card rolls off to {lightnessPhrase(toneCurve(MIDDLE_GREY * 4))}; after the
        curve, it clips to white. Redlamp applies Exposure first, in scene light.
      </>
    ) : (
      <>
        With no curve, the screen shows scene light as it is, up to white: the grey card reads L* {lstar(MIDDLE_GREY).toFixed(1)} instead of{" "}
        {lstar(toneCurve(MIDDLE_GREY)).toFixed(1)}, and everything from 1.0, {whiteStop.toFixed(1)} stops over the grey card, clips, where the tone curve
        rolls highlights off up to {CURVE_WHITE.toFixed(2)}, {curveWhiteStop.toFixed(0)} stops over. It looks flat, but each grey lands at its own L*,
        which is what reproduction work measures.
      </>
    );
  return (
    <Figure
      title="Exposure playground"
      sub="An illustrative scene, from a deep shadow to a street lamp. Exposure multiplies every scene value, so dragging it slides every object along the scale."
    >
      <div className="flex flex-col gap-7">
        <div className="flex flex-col gap-4">
          <div>
            <div className="flex flex-wrap items-center justify-between gap-3">
              <p className="text-[14px] text-mute">
                Exposure <Num>{signed(ev)} EV</Num>: every scene value × <Num>{gain < 1 ? gain.toFixed(3) : gain.toFixed(2)}</Num>
              </p>
              <div className="flex gap-2">
                {[-2, 0, 2].map((preset) => (
                  <Chip key={preset} active={Math.abs(ev - preset) < 0.05} onClick={() => setEv(preset)}>
                    {preset === 0 ? "0 EV" : `${signed(preset, 0)} EV`}
                  </Chip>
                ))}
              </div>
            </div>
            <div className="mt-3">
              <Slider label="Exposure, in stops" min={-4} max={4} step={0.1} value={ev} onChange={setEv} />
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <p className="text-[14px] text-mute">Compare with</p>
            <Toggle
              label="Compare with"
              options={[
                { value: "after", label: "Exposure after the curve" },
                { value: "none", label: "No curve" },
              ]}
              value={mode}
              onChange={setMode}
            />
          </div>
        </div>
        <div>
          <ToneChart ev={ev} mode={mode} />
          <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2">
            <LegendLine label="Exposure, then Redlamp's tone curve" colour={ink.accent} />
            <LegendLine
              label={mode === "after" ? "The tone curve, then Exposure" : "No curve: scene light up to white"}
              colour={ink.compare}
              dashed
            />
          </div>
        </div>
        <div className="grid gap-x-4 gap-y-4 sm:grid-cols-[150px_minmax(0,1fr)]">
          <div className="hidden sm:block" />
          <Six>
            {rows.map((row) => (
              <p key={row.name} className="text-center text-[12px] leading-tight text-mute">
                {row.name}
              </p>
            ))}
          </Six>
          <RowLabel title="Scene value" sub="After Exposure; above 1.0 in colour" />
          <Six>
            {rows.map((row) => (
              <p key={row.name} className="text-center text-[13px]">
                <Num className={row.scene > 1 ? "text-filament" : "text-paper"}>{sceneText(row.scene)}</Num>
              </p>
            ))}
          </Six>
          <RowLabel title="Exposure, then the curve" sub="Scene-referred editing, as Redlamp does it; L* under each patch" />
          <Six>
            {rows.map((row) => (
              <PatchCell key={row.name} light={row.first} />
            ))}
          </Six>
          <RowLabel
            title={mode === "after" ? "The curve, then Exposure" : "Exposure, no curve"}
            sub={mode === "after" ? "Editing the finished render" : "Scene light up to white"}
          />
          <Six>
            {rows.map((row) => (
              <PatchCell key={row.name} light={row.compare} />
            ))}
          </Six>
        </div>
        <p className="max-w-3xl text-[14px] leading-relaxed text-mute">{explanation}</p>
      </div>
    </Figure>
  );
}
