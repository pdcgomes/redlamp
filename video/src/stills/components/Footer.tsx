import type { CSSProperties } from "react";
import { Lockup } from "../../components/Media";
import { color, font } from "../../theme";
import { margin, type } from "../canvas";

/** The lockup and the address, as small print in a corner of every image. */
export function Footer({ style }: { style?: CSSProperties }) {
  return (
    <div
      style={{
        position: "absolute",
        left: margin,
        bottom: 36,
        display: "flex",
        alignItems: "center",
        gap: 18,
        fontFamily: font.family,
        fontSize: type.small,
        color: color.mute,
        ...style,
      }}
    >
      <Lockup width={122} />
      <span style={{ paddingTop: 3 }}>redlamp.app</span>
    </div>
  );
}
