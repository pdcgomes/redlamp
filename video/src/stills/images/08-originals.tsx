import type { CSSProperties, ReactNode } from "react";
import { glass } from "../../components/Media";
import { color, font } from "../../theme";
import { margin, type } from "../canvas";
import { floating } from "../components/Card";
import { Headline } from "../components/Headline";
import { Chip } from "../components/Marks";
import { Shot } from "../components/Shot";
import { StillFrame } from "../components/StillFrame";

/** Non-destructive by design: the original, and the small edit file next to it. */
export function Originals() {
  return (
    <StillFrame index={7}>
      <div style={{ position: "absolute", left: margin, top: 92, width: 600 }}>
        <Headline title="Your photos stay yours." sub="Edits live in a small file next to each photo." />
        <div style={{ marginTop: 40, display: "flex", gap: 14, flexWrap: "wrap" }}>
          <Chip size={34}>No subscription</Chip>
          <Chip size={34}>No cloud</Chip>
          <Chip size={34}>Open source</Chip>
        </div>
      </div>
      <div style={{ position: "absolute", left: 780, top: 150, filter: "drop-shadow(0 40px 70px rgba(0,0,0,0.7))" }}>
        <Shot name="hero" width={900} />
      </div>
      <Files style={{ position: "absolute", left: 600, top: 560 }} />
    </StillFrame>
  );
}

function Files({ style }: { style: CSSProperties }) {
  return (
    <div style={{ ...glass, width: 640, padding: "14px 0", boxShadow: floating, fontFamily: font.family, ...style }}>
      <Row icon={<RawIcon />} name="IMG_1234.ARW" note="Your original, never touched" />
      <div style={{ height: 1, background: color.hairline, margin: "0 24px" }} />
      <Row icon={<EditIcon />} name="IMG_1234.ARW.redlamp" note="Your edit" />
    </div>
  );
}

function Row({ icon, name, note }: { icon: ReactNode; name: string; note: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 20, padding: "14px 24px" }}>
      {icon}
      <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
        <span style={{ fontSize: 30, color: color.paper }}>{name}</span>
        <span style={{ fontSize: type.small + 2, color: color.mute }}>{note}</span>
      </div>
    </div>
  );
}

/** A photo file's icon: a page with a folded corner and a picture on it. */
function RawIcon() {
  return (
    <svg width={52} height={62} viewBox="0 0 52 62">
      <path d="M4 2h30l14 14v42a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z" fill="#e9e3dc" />
      <path d="M34 2v12a2 2 0 0 0 2 2h12" fill="#cfc7bf" />
      <rect x="9" y="26" width="34" height="24" rx="2" fill="#5f7d8f" />
      <path d="M9 44l10-10 8 8 6-5 10 9v2a2 2 0 0 1-2 2H11a2 2 0 0 1-2-2z" fill="#a6b98d" />
    </svg>
  );
}

/** The sidecar package's icon: a page of settings. */
function EditIcon() {
  return (
    <svg width={52} height={62} viewBox="0 0 52 62">
      <path d="M4 2h30l14 14v42a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z" fill="#3a3230" />
      <path d="M34 2v12a2 2 0 0 0 2 2h12" fill="#57504e" />
      {[26, 34, 42, 50].map((y, i) => (
        <g key={y}>
          <rect x="9" y={y - 1} width="34" height="2" rx="1" fill="#6f6561" />
          <circle cx={14 + ((i * 9) % 24)} cy={y} r="3.2" fill={color.ring} />
        </g>
      ))}
    </svg>
  );
}
