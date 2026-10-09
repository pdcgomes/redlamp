import type { ReactNode } from "react";
import { greyCss } from "@/lib/tone";

/** The colours figures draw charts with, from the site's palette (`app/globals.css`). */
export const ink = {
  grid: "rgb(243 238 232 / 0.08)",
  shade: "rgb(243 238 232 / 0.04)",
  marker: "rgb(243 238 232 / 0.24)",
  tick: "#6f6561",
  label: "#a89d98",
  accent: "#ffb08a",
  compare: "rgb(243 238 232 / 0.72)",
  quiet: "rgb(217 208 203 / 0.45)",
  surface: "#1c1615",
};

export function Figure({ title, sub, caption, children }: { title?: string; sub?: ReactNode; caption?: ReactNode; children: ReactNode }) {
  return (
    <figure className="surface p-5 sm:p-7">
      {title ? (
        <div className="mb-6">
          <p className="font-display text-[18px] leading-snug text-paper">{title}</p>
          {sub ? <p className="mt-1.5 max-w-3xl text-[14px] leading-relaxed text-mute">{sub}</p> : null}
        </div>
      ) : null}
      {children}
      {caption ? <figcaption className="mt-6 max-w-3xl text-[13px] leading-relaxed text-dim">{caption}</figcaption> : null}
    </figure>
  );
}

export function LegendLine({ label, colour, dashed }: { label: ReactNode; colour: string; dashed?: boolean }) {
  return (
    <span className="inline-flex items-center gap-2 text-[13px] text-mute">
      <svg width="22" height="8" aria-hidden className="shrink-0">
        <line x1="0" y1="4" x2="22" y2="4" stroke={colour} strokeWidth="2" strokeDasharray={dashed ? "4 3" : undefined} />
      </svg>
      {label}
    </span>
  );
}

export function LegendSwatch({ label, colour }: { label: ReactNode; colour: string }) {
  return (
    <span className="inline-flex items-center gap-2 text-[13px] text-mute">
      <span aria-hidden className="size-2.5 shrink-0 rounded-[3px]" style={{ background: colour }} />
      {label}
    </span>
  );
}

export function Num({ children, className = "text-paper" }: { children: ReactNode; className?: string }) {
  return <span className={`font-mono tabular-nums ${className}`}>{children}</span>;
}

/** A grey patch showing a display light, as the sRGB curve writes it. */
export function Patch({ light, className = "h-9" }: { light: number; className?: string }) {
  return <div className={`rounded-md border border-hairline ${className}`} style={{ background: greyCss(light) }} />;
}

export function sourceLink(path: string): string {
  return `https://github.com/pdcgomes/redlamp/blob/main/${path}`;
}

export const textLink = "text-paper underline decoration-hairline-strong underline-offset-3 hover:decoration-paper";
