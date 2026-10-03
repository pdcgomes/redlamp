import type { CSSProperties } from "react";
import { Img } from "remotion";
import { capture } from "../assets";
import { font, neutral } from "../style";

/** A rectangle in a window's points. Editor captures are 1600 × 1000 of them, at 2×. */
export type Region = { x: number; y: number; width: number; height: number };

export const editor = { width: 1600, height: 1000 } as const;
export const whole: Region = { x: 0, y: 0, ...editor };

/**
 * Where things sit in a 1600 × 1000 editor capture, in points: Basic's Tone and Presence groups,
 * the command palette open over the photo, and the Keyboard Shortcuts sheet.
 */
export const regions = {
  basicTone: { x: 1284, y: 418, width: 316, height: 318 },
  palette: { x: 490, y: 64, width: 620, height: 423 },
  shortcuts: { x: 260, y: 166, width: 1080, height: 718 },
} satisfies Record<string, Region>;

type Props = {
  name: string;
  region?: Region;
  /** Width on screen, in pixels; the height follows the region. */
  width: number;
  /** The captured window's width in points, for windows other than the editor. */
  captureWidth?: number;
  radius?: number;
  style?: CSSProperties;
};

/** A region of a window capture from scripts/capture-promo.sh, or a labelled stand-in until there is one. */
export function Capture({ name, region = whole, width, captureWidth = editor.width, radius = 0, style }: Props) {
  const src = capture(name);
  const scale = width / region.width;
  return (
    <div style={{ position: "relative", width, height: region.height * scale, overflow: "hidden", borderRadius: radius, ...style }}>
      {src ? (
        <Img
          src={src}
          style={{ position: "absolute", left: -region.x * scale, top: -region.y * scale, width: captureWidth * scale, height: "auto" }}
        />
      ) : (
        <div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: neutral.lift,
            border: `2px dashed ${neutral.tertiary}`,
            borderRadius: "inherit",
            fontFamily: font.family,
            fontSize: 20,
            color: neutral.secondary,
          }}
        >
          film/captures/{name}.png
        </div>
      )}
    </div>
  );
}
