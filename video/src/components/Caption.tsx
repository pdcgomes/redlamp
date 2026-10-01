import type { CSSProperties } from "react";
import { interpolate, useCurrentFrame } from "remotion";
import { color, easeOut, font } from "../theme";

type Props = {
  title: string;
  sub?: string;
  start?: number;
  /** Frame the caption starts leaving; omit to stay. */
  end?: number;
  align?: "left" | "center";
  size?: number;
  style?: CSSProperties;
};

/** Words arrive one after another, rising out of a soft blur, like a print coming up in the tray. */
export function Caption({ title, sub, start = 0, end, align = "left", size = 64, style }: Props) {
  const frame = useCurrentFrame();
  const words = title.split(" ");
  const exit = end === undefined ? 1 : interpolate(frame, [end, end + 12], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const subIn = interpolate(frame, [start + 10 + words.length * 3, start + 34 + words.length * 3], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: easeOut,
  });
  return (
    <div style={{ textAlign: align, opacity: exit, fontFamily: font.family, ...style }}>
      <div
        style={{
          ...font.display,
          fontSize: size,
          lineHeight: 1.08,
          color: color.paper,
          display: "flex",
          flexWrap: "wrap",
          justifyContent: align === "center" ? "center" : "flex-start",
          columnGap: size * 0.26,
        }}
      >
        {words.map((word, i) => {
          const t = interpolate(frame, [start + i * 3, start + i * 3 + 22], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: easeOut,
          });
          return (
            <span
              key={`${word}-${i}`}
              style={{ opacity: t, transform: `translateY(${(1 - t) * size * 0.35}px)`, filter: `blur(${(1 - t) * 8}px)` }}
            >
              {word}
            </span>
          );
        })}
      </div>
      {sub ? (
        <div
          style={{
            marginTop: size * 0.38,
            fontSize: size * 0.42,
            lineHeight: 1.4,
            color: color.mute,
            opacity: subIn,
            transform: `translateY(${(1 - subIn) * 12}px)`,
          }}
        >
          {sub}
        </div>
      ) : null}
    </div>
  );
}
