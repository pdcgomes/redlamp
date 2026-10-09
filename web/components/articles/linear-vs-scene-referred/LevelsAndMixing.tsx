"use client";

import { type ReactNode, useEffect, useState } from "react";
import { clamp, level8, srgbDecode, srgbEncode } from "@/lib/tone";
import { useWidth } from "../interactive";
import { Figure, LegendSwatch, ink } from "../parts";

const stops = [1, 2, 3, 4, 5, 6, 7, 8];
const linear = stops.map((stop) => Math.round(255 * (2 ** -(stop - 1) - 2 ** -stop)));
const srgb = stops.map((stop) => Math.round(255 * (srgbEncode(2 ** -(stop - 1)) - srgbEncode(2 ** -stop))));

function LevelsChart() {
  const [ref, width] = useWidth<HTMLDivElement>(420);
  const height = 236;
  const left = 40;
  const right = width - 6;
  const top = 18;
  const bottom = height - 40;
  const y = (levels: number) => bottom - (levels / 128) * (bottom - top);
  const band = (right - left) / stops.length;
  const bar = clamp(band * 0.32, 5, 22);
  const labelled = bar >= 12;
  return (
    <div ref={ref}>
      <svg
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label="How many of 256 levels fall in each of the eight stops below white, written linearly and with the sRGB curve"
        className="block h-auto w-full"
      >
        {[0, 32, 64, 96, 128].map((levels) => (
          <g key={levels}>
            <line x1={left} x2={right} y1={y(levels)} y2={y(levels)} stroke={ink.grid} />
            <text x={left - 8} y={y(levels) + 4} textAnchor="end" fontSize="11" fill={ink.tick}>
              {levels}
            </text>
          </g>
        ))}
        {stops.map((stop, index) => {
          const centre = left + band * (index + 0.5);
          return (
            <g key={stop}>
              <rect x={centre - bar - 1} y={y(linear[index])} width={bar} height={bottom - y(linear[index])} rx="2" fill={ink.quiet} />
              <rect x={centre + 1} y={y(srgb[index])} width={bar} height={bottom - y(srgb[index])} rx="2" fill={ink.accent} />
              {labelled ? (
                <>
                  <text x={centre - bar / 2 - 1} y={y(linear[index]) - 5} textAnchor="middle" fontSize="10" fill={ink.label}>
                    {linear[index]}
                  </text>
                  <text x={centre + bar / 2 + 1} y={y(srgb[index]) - 5} textAnchor="middle" fontSize="10" fill={ink.label}>
                    {srgb[index]}
                  </text>
                </>
              ) : null}
              <text x={centre} y={bottom + 16} textAnchor="middle" fontSize="11" fill={ink.tick}>
                {stop}
              </text>
            </g>
          );
        })}
        <text x={(left + right) / 2} y={height - 6} textAnchor="middle" fontSize="11" fill={ink.label}>
          Stop below white (1 is the brightest)
        </text>
        <text transform={`translate(11 ${(top + bottom) / 2}) rotate(-90)`} textAnchor="middle" fontSize="11" fill={ink.label}>
          Levels, of 256
        </text>
      </svg>
    </div>
  );
}

function Swatch({ label, sub, children }: { label: string; sub: string; children: ReactNode }) {
  return (
    <div className="w-[88px]">
      <div className="w-fit overflow-hidden rounded-md border border-hairline-strong leading-[0]">{children}</div>
      <p className="mt-2 text-[13px] leading-snug font-medium text-paper">{label}</p>
      <p className="mt-0.5 text-[12px] leading-snug text-dim">{sub}</p>
    </div>
  );
}

function Mixing() {
  const [ratio, setRatio] = useState(1);
  useEffect(() => {
    if (Number.isInteger(window.devicePixelRatio)) setRatio(window.devicePixelRatio);
  }, []);
  const size = 76;
  const lines = [];
  for (let row = 0; row < size * ratio; row += 2) {
    lines.push(<rect key={row} x={0} y={row / ratio} width={size} height={1 / ratio} fill="rgb(255 255 255)" />);
  }
  const lightAverage = level8(0.5);
  const numberAverage = 128;
  return (
    <div className="flex flex-wrap gap-4">
      <Swatch label="Black and white lines" sub="half of white's light">
        <svg width={size} height={size} shapeRendering="crispEdges" aria-hidden className="block">
          <rect width={size} height={size} fill="rgb(0 0 0)" />
          {lines}
        </svg>
      </Swatch>
      <Swatch label={`${lightAverage} of 255`} sub="averaging the light: 50%">
        <div style={{ width: size, height: size, background: `rgb(${lightAverage} ${lightAverage} ${lightAverage})` }} />
      </Swatch>
      <Swatch label={`${numberAverage} of 255`} sub={`averaging the numbers: ${Math.round(100 * srgbDecode(numberAverage / 255))}%`}>
        <div style={{ width: size, height: size, background: `rgb(${numberAverage} ${numberAverage} ${numberAverage})` }} />
      </Swatch>
    </div>
  );
}

export function LevelsAndMixing() {
  return (
    <div className="grid gap-4 md:grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)]">
      <Figure
        title="8-bit levels in each stop below white"
        sub="How many of an 8-bit file's 256 levels fall in each stop, written linearly and with the sRGB curve."
        caption="Linear spends half of its 256 levels on the brightest stop and leaves 2 for the seventh, where shadows would band; the sRGB curve spreads them out. Redlamp computes in floating point, where linear numbers lose nothing."
      >
        <LevelsChart />
        <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2">
          <LegendSwatch label="Linear" colour={ink.quiet} />
          <LegendSwatch label="sRGB curve" colour={ink.accent} />
        </div>
      </Figure>
      <Figure
        title="Light adds; stored numbers don't"
        sub="Half black, half white: what's the average?"
        caption="Step back or squint: the lines blend into the middle patch, not the right one. A blur, resize or blend done on sRGB-encoded numbers makes mixes too dark, and leaves dark fringes around bright edges. View at 100% zoom."
      >
        <Mixing />
      </Figure>
    </div>
  );
}
