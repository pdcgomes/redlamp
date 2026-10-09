"use client";

import { useState } from "react";
import { MIDDLE_GREY, clamp, level8, lstar, srgbEncode } from "@/lib/tone";
import { percentText } from "../format";
import { Chip, Slider, useWidth } from "../interactive";
import { Figure, LegendLine, Num, ink } from "../parts";

const grey = Math.log2(MIDDLE_GREY);

function EncodingChart({ light }: { light: number }) {
  const [ref, width] = useWidth<HTMLDivElement>(420);
  const height = Math.round(clamp(width * 0.72, 220, 320));
  const left = 44;
  const right = width - 10;
  const top = 10;
  const bottom = height - 40;
  const x = (v: number) => left + v * (right - left);
  const y = (v: number) => bottom - v * (bottom - top);
  const path = (f: (v: number) => number) =>
    Array.from({ length: 121 }, (_, i) => {
      const v = (i / 120) ** 2;
      return `${i === 0 ? "M" : "L"}${x(v).toFixed(1)},${y(f(v)).toFixed(1)}`;
    }).join(" ");
  const ticks = [0, 0.25, 0.5, 0.75, 1];
  const dots = [
    { value: light, colour: ink.quiet },
    { value: lstar(light) / 100, colour: ink.compare },
    { value: srgbEncode(light), colour: ink.accent },
  ];
  return (
    <div ref={ref}>
      <svg
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label="The value stored for each amount of light, written linearly, with the sRGB curve and with the L* curve"
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
        <path d={path((v) => v)} fill="none" stroke={ink.quiet} strokeWidth="1.5" />
        <path d={path((v) => lstar(v) / 100)} fill="none" stroke={ink.compare} strokeWidth="1.5" strokeDasharray="4 3" />
        <path d={path(srgbEncode)} fill="none" stroke={ink.accent} strokeWidth="2.25" />
        <line x1={x(light)} x2={x(light)} y1={top} y2={bottom} stroke={ink.marker} strokeDasharray="3 3" />
        {dots.map((dot) => (
          <circle key={dot.colour} cx={x(light)} cy={y(dot.value)} r="4" fill={dot.colour} stroke={ink.surface} strokeWidth="1.5" />
        ))}
        <text x={(left + right) / 2} y={height - 6} textAnchor="middle" fontSize="11" fill={ink.label}>
          Light, as a fraction of white
        </text>
        <text transform={`translate(12 ${(top + bottom) / 2}) rotate(-90)`} textAnchor="middle" fontSize="11" fill={ink.label}>
          Stored value (× 255 for 8 bits)
        </text>
      </svg>
    </div>
  );
}

export function Encoding() {
  const [stops, setStops] = useState(grey);
  const light = 2 ** stops;
  const l = lstar(light);
  const rows: [string, string, string][] = [
    ["Linear", light.toFixed(3), String(Math.round(255 * light))],
    ["sRGB curve (sRGB, Display P3)", srgbEncode(light).toFixed(3), String(level8(light))],
    ["L* curve (eciRGB v2)", (l / 100).toFixed(3), String(Math.round(2.55 * l))],
  ];
  return (
    <Figure title="Stored value for each amount of light" sub="Three ways of writing the same light, from black to white. Drag the light to compare them.">
      <div className="grid gap-8 md:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)]">
        <div>
          <EncodingChart light={light} />
          <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2">
            <LegendLine label="Linear" colour={ink.quiet} />
            <LegendLine label="sRGB curve" colour={ink.accent} />
            <LegendLine label="L* curve (eciRGB v2): L* ÷ 100" colour={ink.compare} dashed />
          </div>
        </div>
        <div className="flex flex-col gap-5">
          <div>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="text-[14px] text-mute">
                Light: <Num>{percentText(light)}</Num> of white, <Num>{(-stops).toFixed(2)}</Num> stops below it
              </p>
              <Chip active={Math.abs(stops - grey) < 0.005} onClick={() => setStops(grey)}>
                18% grey
              </Chip>
            </div>
            <div className="mt-3">
              <Slider label="Light, in stops below white" min={-8} max={0} step={0.01} value={stops} onChange={setStops} />
            </div>
          </div>
          <table className="w-full text-[14px]">
            <thead>
              <tr className="border-b border-hairline text-[12px] text-dim">
                <th className="py-2 text-left font-medium">Written as</th>
                <th className="py-2 text-right font-medium">Stored value</th>
                <th className="py-2 text-right font-medium">8-bit level</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(([name, value, level]) => (
                <tr key={name} className="border-b border-hairline">
                  <td className="py-2.5 pr-3 text-mute">{name}</td>
                  <td className="py-2.5 text-right">
                    <Num>{value}</Num>
                  </td>
                  <td className="py-2.5 text-right">
                    <Num>{level}</Num>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="text-[14px] leading-relaxed text-mute">
            Middle grey, 18% of white, is 46 of 255 written linearly, 118 with the sRGB curve and 126 with the L* curve that eciRGB v2 uses. L*
            is also the scale the feedback measured in: 18% of white is L* 49.5, near the middle, which is about where it looks.
          </p>
        </div>
      </div>
    </Figure>
  );
}
