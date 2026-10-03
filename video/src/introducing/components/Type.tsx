import type { CSSProperties, ReactNode } from "react";
import { useCurrentFrame } from "remotion";
import { ease, font, ink, ramp, type as typeScale, useShape } from "../style";

type DevelopProps = {
  /** The frame it starts to come up, and the frame it starts to go (if it does). */
  at: number;
  until?: number;
  /** Frames to come up and to go. */
  duration?: number;
  out?: number;
  rise?: number;
  style?: CSSProperties;
  children: ReactNode;
};

/** Words come up the way a print does in the developer: from faint and soft to sharp. */
export function Develop({ at, until, duration = 36, out = 20, rise = 12, style, children }: DevelopProps) {
  const frame = useCurrentFrame();
  const up = ramp(frame, at, duration, ease.out);
  const gone = until === undefined ? 0 : ramp(frame, until, out, ease.inOut);
  return (
    <div
      style={{
        opacity: up * (1 - gone),
        filter: `blur(${(1 - up) * 9 + gone * 7}px)`,
        transform: `translateY(${(1 - up) * rise - gone * 6}px)`,
        ...style,
      }}
    >
      {children}
    </div>
  );
}

type TitleProps = {
  /** Line breaks are kept. */
  title: string;
  sub?: string;
  at: number;
  until?: number;
  align?: "left" | "center";
  width?: number;
  /** Frames between the headline and its subline. */
  gap?: number;
  style?: CSSProperties;
};

/** A headline in Inter Display and, a moment later, its subline. */
export function Title({ title, sub, at, until, align = "left", width, gap = 14, style }: TitleProps) {
  const { shape } = useShape();
  const size = typeScale[shape];
  return (
    <div style={{ width, textAlign: align, fontFamily: font.family, ...style }}>
      <Develop at={at} until={until}>
        <div style={{ ...font.display, fontSize: size.headline, lineHeight: 1.06, color: ink.headline, whiteSpace: "pre-line" }}>
          {title}
        </div>
      </Develop>
      {sub ? (
        <Develop at={at + gap} until={until === undefined ? undefined : until + 4}>
          <div
            style={{
              ...font.text,
              fontSize: size.sub,
              lineHeight: 1.3,
              color: ink.sub,
              marginTop: size.headline * 0.36,
              whiteSpace: "pre-line",
            }}
          >
            {sub}
          </div>
        </Develop>
      ) : null}
    </div>
  );
}
