import type { CSSProperties, ReactNode } from "react";
import { color, font } from "../../theme";
import { type } from "../canvas";

type Props = {
  title: string;
  sub?: ReactNode;
  size?: number;
  subSize?: number;
  width?: number;
  align?: "left" | "center";
  style?: CSSProperties;
};

/** An image's headline in Inter Display, and the one line of copy under it. */
export function Headline({ title, sub, size = type.headline, subSize = type.sub, width, align = "left", style }: Props) {
  return (
    <div style={{ fontFamily: font.family, textAlign: align, width, ...style }}>
      <div style={{ ...font.display, fontSize: size, lineHeight: 1.02, color: color.paper, textWrap: "balance" }}>{title}</div>
      {sub ? (
        <div
          style={{
            marginTop: size * 0.3,
            fontSize: subSize,
            lineHeight: 1.26,
            color: color.mute,
            textWrap: "pretty",
            whiteSpace: "pre-line",
          }}
        >
          {sub}
        </div>
      ) : null}
    </div>
  );
}

/** Text the reader would type, set in the mono face on a faint pill. */
export function Typed({ children }: { children: ReactNode }) {
  return (
    <span
      style={{
        fontFamily: font.mono,
        fontSize: "0.86em",
        color: color.paper,
        padding: "0.04em 0.32em",
        borderRadius: "0.28em",
        background: "rgba(243,238,232,0.1)",
        whiteSpace: "nowrap",
      }}
    >
      {children}
    </span>
  );
}
