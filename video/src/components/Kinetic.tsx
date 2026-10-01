import type { CSSProperties } from "react";
import { spring, useCurrentFrame, useVideoConfig } from "remotion";
import { springs } from "../layout";
import { color, font } from "../theme";

type Props = {
  /** Words appear one after another; `\n` starts a new line. */
  text: string;
  start?: number;
  size: number;
  stagger?: number;
  /** `rise` slides each word up out of its own line; `pop` scales it in from small. */
  mode?: "rise" | "pop";
  /** Frame the words start leaving, upwards. */
  out?: number;
  align?: "left" | "center";
  tone?: "paper" | "mute";
  weight?: number;
  style?: CSSProperties;
};

/** Kinetic type: each word springs into place with a little overshoot. */
export function Words({ text, start = 0, size, stagger = 3, mode = "rise", out, align = "center", tone = "paper", weight, style }: Props) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  let index = 0;
  return (
    <div
      style={{
        fontFamily: font.family,
        ...font.display,
        fontWeight: weight ?? font.display.fontWeight,
        fontSize: size,
        lineHeight: 1.04,
        color: tone === "paper" ? color.paper : color.mute,
        textAlign: align,
        ...style,
      }}
    >
      {text.split("\n").map((line, li) => (
        <div
          key={`${line}-${li}`}
          style={{ display: "flex", whiteSpace: "nowrap", justifyContent: align === "center" ? "center" : "flex-start", columnGap: size * 0.24 }}
        >
          {line.split(" ").map((word) => {
            const i = index++;
            const s = spring({ frame: frame - start - i * stagger, fps, config: springs.pop });
            const o = out === undefined ? 0 : spring({ frame: frame - out - i, fps, config: springs.snap });
            if (mode === "pop") {
              return (
                <span
                  key={`${word}-${i}`}
                  style={{
                    display: "inline-block",
                    opacity: Math.min(1, s * 2) * (1 - o),
                    transform: `translateY(${(1 - s) * size * 0.25 - o * size * 0.4}px) scale(${0.5 + 0.5 * s})`,
                  }}
                >
                  {word}
                </span>
              );
            }
            return (
              <span key={`${word}-${i}`} style={{ display: "inline-block", overflow: "hidden", padding: "0.1em 0.04em", margin: "-0.1em -0.04em" }}>
                <span
                  style={{
                    display: "inline-block",
                    transformOrigin: "0 100%",
                    transform: `translateY(${(1 - s) * 115 - o * 115}%) rotate(${(1 - s) * 8}deg)`,
                  }}
                >
                  {word}
                </span>
              </span>
            );
          })}
        </div>
      ))}
    </div>
  );
}
