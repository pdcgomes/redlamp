"use client";

import { useMemo, useState } from "react";
import { type Look, anchorExposure, clamp, greyCss, lookCurve, lstar, luminanceOf, MIDDLE_GREY } from "@/lib/tone";
import { signed } from "../format";
import { Chip, Slider, Toggle, useWidth } from "../interactive";
import { Figure, LegendLine, Num, ink, sourceLink, textLink } from "../parts";

const patches = [
  { name: "Black 2", reference: 20.5 },
  { name: "Neutral 3.5", reference: 35.7 },
  { name: "Neutral 5", reference: 50.9 },
  { name: "Neutral 6.5", reference: 66.8 },
  { name: "Neutral 8", reference: 81.3 },
  { name: "White 9.5", reference: 96.5 },
];
const anchorPatch = patches[2];

const lookNames: Record<Look, string> = { neutral: "Redlamp Neutral", color: "Redlamp Color" };

function rendered(reference: number, ev: number, look: Look): number {
  return lstar(lookCurve(luminanceOf(reference) * 2 ** ev, look));
}

function Plot({ ev, look }: { ev: number; look: Look }) {
  const [ref, width] = useWidth<HTMLDivElement>(420);
  const left = 44;
  const right = width - 10;
  const top = 10;
  const bottom = top + Math.min(right - left, 360);
  const height = bottom + 40;
  const x = (l: number) => left + (clamp(l, 0, 100) / 100) * (right - left);
  const y = (l: number) => bottom - (clamp(l, 0, 100) / 100) * (bottom - top);
  const curve = Array.from({ length: 101 }, (_, l) => `${l === 0 ? "M" : "L"}${x(l).toFixed(1)},${y(rendered(l, ev, look)).toFixed(1)}`).join(" ");
  const ticks = [0, 25, 50, 75, 100];
  return (
    <div ref={ref}>
      <svg
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label="Each grey patch's rendered L* against its reference L*, with the diagonal a linear response would follow"
        className="block h-auto w-full"
      >
        {ticks.map((tick) => (
          <g key={tick}>
            <line x1={x(tick)} x2={x(tick)} y1={top} y2={bottom} stroke={ink.grid} />
            <line x1={left} x2={right} y1={y(tick)} y2={y(tick)} stroke={ink.grid} />
            <text x={x(tick)} y={bottom + 16} textAnchor="middle" fontSize="11" fill={ink.tick}>
              {tick}
            </text>
            <text x={left - 8} y={y(tick) + 4} textAnchor="end" fontSize="11" fill={ink.tick}>
              {tick}
            </text>
          </g>
        ))}
        <line x1={x(0)} y1={y(0)} x2={x(100)} y2={y(100)} stroke={ink.compare} strokeWidth="1.5" strokeDasharray="5 4" />
        <path d={curve} fill="none" stroke={ink.accent} strokeWidth="2.25" />
        {patches.map((patch) => {
          const l = rendered(patch.reference, ev, look);
          return (
            <g key={patch.name}>
              <line x1={x(patch.reference)} x2={x(patch.reference)} y1={y(patch.reference)} y2={y(l)} stroke={ink.marker} strokeWidth="1.5" />
              <circle cx={x(patch.reference)} cy={y(patch.reference)} r="3.5" fill={ink.surface} stroke={ink.compare} strokeWidth="1.5" />
              <circle cx={x(patch.reference)} cy={y(l)} r="4" fill={ink.accent} stroke={ink.surface} strokeWidth="1.5" />
            </g>
          );
        })}
        <text x={(left + right) / 2} y={height - 6} textAnchor="middle" fontSize="11" fill={ink.label}>
          Patch&apos;s reference L*, the chart&apos;s own
        </text>
        <text transform={`translate(12 ${(top + bottom) / 2}) rotate(-90)`} textAnchor="middle" fontSize="11" fill={ink.label}>
          Rendered L*
        </text>
      </svg>
    </div>
  );
}

export function GreyScale() {
  const [look, setLook] = useState<Look>("neutral");
  const [ev, setEv] = useState(0);
  const anchor = useMemo(() => anchorExposure(anchorPatch.reference, look), [look]);
  const anchoredNeutral = useMemo(() => {
    const exposure = anchorExposure(anchorPatch.reference, "neutral");
    return patches.map((patch) => rendered(patch.reference, exposure, "neutral"));
  }, []);
  const rows = patches.map((patch) => {
    const l = rendered(patch.reference, ev, look);
    return { ...patch, rendered: l, gap: l - patch.reference };
  });
  const worst = rows.reduce((a, b) => (Math.abs(b.gap) > Math.abs(a.gap) ? b : a));
  return (
    <Figure
      title="A ColorChecker's grey row through Redlamp's tone curve"
      sub="A linear response is the dashed diagonal: every patch at its own L*. Drag Exposure, or anchor middle grey, and try to put all six on it. Redlamp Neutral and Redlamp Color are two of its built-in looks; Neutral has the lower contrast."
      caption={
        <>
          Model: Redlamp&apos;s tone curve with each look&apos;s contrast, as{" "}
          <a className={textLink} href={sourceLink("research/tone-reproduction/greyscale.py")}>
            greyscale.py
          </a>{" "}
          models it, with each patch&apos;s scene value at its reflectance × 2<sup>Exposure</sup>, so 0 EV puts an 18% grey at 0.18. Anchored under
          Neutral, it gives White {anchoredNeutral[5].toFixed(1)}, Neutral 8 {anchoredNeutral[4].toFixed(1)} and Black {anchoredNeutral[0].toFixed(1)}.
          Redlamp&apos;s renders of a CC0 raw of a ColorChecker from a Sigma fp, anchored the same way, measured 86.3, 78.1 and 17.3: flare in a real
          photo lifts the black. Reference L*: BabelColor&apos;s averages for the ColorChecker.
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <div className="flex flex-wrap items-center gap-3">
          <Toggle
            label="Look"
            options={(["neutral", "color"] as Look[]).map((value) => ({ value, label: lookNames[value] }))}
            value={look}
            onChange={setLook}
          />
          <button type="button" onClick={() => setEv(anchor)} className="button-secondary rounded-pill px-3.5 py-1 text-[13px] transition-colors">
            Anchor middle grey
          </button>
          <Chip active={ev === 0} onClick={() => setEv(0)}>
            0 EV
          </Chip>
        </div>
        <div>
          <p className="text-[14px] text-mute">
            Exposure <Num>{signed(ev, 2)} EV</Num>: an 18% grey sits at <Num>{(MIDDLE_GREY * 2 ** ev).toFixed(3)}</Num> in scene light
          </p>
          <div className="mt-3">
            <Slider label="Exposure for the grey scale, in stops" min={-2} max={2} step={0.01} value={ev} onChange={setEv} />
          </div>
        </div>
      </div>
      <div className="mt-7 grid gap-8 md:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
        <div>
          <Plot ev={ev} look={look} />
          <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2">
            <LegendLine label="Linear response: no curve" colour={ink.compare} dashed />
            <LegendLine label={lookNames[look]} colour={ink.accent} />
          </div>
        </div>
        <div className="flex flex-col gap-6">
          <table className="w-full text-[14px]">
            <thead>
              <tr className="border-b border-hairline text-[12px] text-dim">
                <th className="py-2 text-left font-medium">Patch</th>
                <th className="py-2 text-center font-medium">Chart, render</th>
                <th className="py-2 text-right font-medium">Ref</th>
                <th className="py-2 text-right font-medium">Render</th>
                <th className="py-2 text-right font-medium">Gap</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.name} className="border-b border-hairline">
                  <td className="py-2 pr-2 text-mute">{row.name}</td>
                  <td className="py-2">
                    <span className="flex justify-center gap-1">
                      <span className="block h-5 w-6 rounded-[4px] border border-hairline" style={{ background: greyCss(luminanceOf(row.reference)) }} />
                      <span className="block h-5 w-6 rounded-[4px] border border-hairline" style={{ background: greyCss(luminanceOf(row.rendered)) }} />
                    </span>
                  </td>
                  <td className="py-2 text-right">
                    <Num>{row.reference.toFixed(1)}</Num>
                  </td>
                  <td className="py-2 text-right">
                    <Num>{row.rendered.toFixed(1)}</Num>
                  </td>
                  <td className="py-2 text-right">
                    <Num className={Math.abs(row.gap) <= 1 ? "text-dim" : "text-paper"}>{signed(row.gap)}</Num>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <div>
            <p className={`font-display text-[32px] leading-none tabular-nums ${Math.abs(worst.gap) > 2 ? "text-filament" : "text-paper"}`}>
              {signed(worst.gap)}
            </p>
            <p className="mt-2 text-[13px] text-dim">Largest gap in L*, at {worst.name}</p>
          </div>
          <p className="text-[14px] leading-relaxed text-mute">
            Anchoring puts Neutral 5 on its reference, but the curve&apos;s toe still pulls the dark patches down and its shoulder pulls White down: no
            exposure puts all six on the diagonal. A reproduction mode has to replace the curve, not adjust it.
          </p>
        </div>
      </div>
    </Figure>
  );
}
