import type { ReactNode } from "react";
import { font, neutral } from "../style";

export type HistoryRow = { icon: ReactNode; name: string; before?: string; after?: string; shown: number };

/**
 * The History panel as the app's left column draws it (HistoryRowViews): the step's name, and
 * its values right-aligned, the one before dimmed and the arrow fainter still. The newest step is
 * at the top and highlighted.
 */
export function History({ rows, width, rowHeight, size, current }: { rows: HistoryRow[]; width: number; rowHeight: number; size: number; current: number }) {
  return (
    <div
      style={{
        width,
        borderRadius: size * 0.7,
        background: neutral.panel,
        boxShadow: `inset 0 0 0 1px ${neutral.hairline}, 0 30px 80px rgba(0,0,0,0.45)`,
        padding: `${size * 0.5}px ${size * 0.45}px ${size * 0.6}px`,
        fontFamily: font.family,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: size * 0.4, height: rowHeight * 0.9, padding: `0 ${size * 0.35}px` }}>
        <svg width={size * 0.55} height={size * 0.55} viewBox="0 0 12 12">
          <path d="M3 4.5 6 7.5 9 4.5" fill="none" stroke={neutral.secondary} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        <span style={{ ...font.text, fontWeight: 600, fontSize: size * 0.92, color: neutral.label }}>History</span>
      </div>
      {rows.map((row, i) => (
        <div
          key={row.name}
          style={{
            display: "flex",
            alignItems: "center",
            gap: size * 0.5,
            height: rowHeight,
            padding: `0 ${size * 0.5}px`,
            borderRadius: size * 0.35,
            background: i === current ? `rgba(255,255,255,${0.1 * row.shown})` : "transparent",
            opacity: row.shown,
            transform: `translateX(${(1 - row.shown) * -10}px)`,
            fontSize: size,
          }}
        >
          <span style={{ display: "flex", color: neutral.secondary }}>{row.icon}</span>
          <span style={{ ...font.text, color: neutral.label, flex: 1 }}>{row.name}</span>
          {row.after ? (
            <span style={{ ...font.text, fontVariantNumeric: "tabular-nums", whiteSpace: "nowrap" }}>
              {row.before ? (
                <>
                  <span style={{ color: neutral.secondary }}>{row.before}</span>
                  <span style={{ color: neutral.tertiary }}> → </span>
                </>
              ) : null}
              <span style={{ color: "rgba(255,255,255,0.9)" }}>{row.after}</span>
            </span>
          ) : null}
        </div>
      ))}
    </div>
  );
}
