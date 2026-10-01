import { createContext, useContext, type CSSProperties, type ReactNode } from "react";
import { getStaticFiles, Img, staticFile } from "remotion";
import { color, font } from "../../theme";
import { captureSize } from "../canvas";

/** A rectangle in the editor window's points. A capture is 1600 × 1000 of them. */
export type Region = { x: number; y: number; width: number; height: number };

export const wholeWindow: Region = { x: 0, y: 0, width: captureSize.width, height: captureSize.height };

/**
 * The image behind a shot: the capture `promo/<name>.png` if there is one, otherwise the stand-in
 * (a path in public/, such as a README screenshot taken at the same window width), otherwise none.
 */
function useSource(name: string, standIn?: string): string | null {
  const files = new Set(getStaticFiles().map((file) => file.name));
  if (files.has(`promo/${name}.png`)) return staticFile(`promo/${name}.png`);
  if (standIn && files.has(standIn)) return staticFile(standIn);
  return null;
}

type Space = { region: Region; scale: number };
const ShotSpace = createContext<Space>({ region: wholeWindow, scale: 1 });

/** Marks inside a shot place themselves in window points through this. */
export function useShotSpace(): Space {
  return useContext(ShotSpace);
}

export type ShotProps = {
  /** The capture's name in video/public/promo, without `.png`. */
  name: string;
  region?: Region;
  /** Width on the canvas, in points. The height follows the region. */
  width: number;
  /** The captured window's width in points, for windows other than the editor (such as Film Looks). */
  captureWidth?: number;
  standIn?: string;
  radius?: number;
  style?: CSSProperties;
  children?: ReactNode;
};

/** A region of a window capture at `width` canvas points, or a labelled placeholder until it's captured. */
export function Shot({
  name,
  region = wholeWindow,
  width,
  captureWidth = captureSize.width,
  standIn,
  radius = 0,
  style,
  children,
}: ShotProps) {
  const src = useSource(name, standIn);
  const scale = width / region.width;
  return (
    <div style={{ position: "relative", width, height: region.height * scale, overflow: "hidden", borderRadius: radius, ...style }}>
      {src ? (
        <Img
          src={src}
          style={{
            position: "absolute",
            left: -region.x * scale,
            top: -region.y * scale,
            width: captureWidth * scale,
            height: "auto",
          }}
        />
      ) : (
        <Placeholder name={name} region={region} />
      )}
      <ShotSpace.Provider value={{ region, scale }}>{children}</ShotSpace.Provider>
    </div>
  );
}

function Placeholder({ name, region }: { name: string; region: Region }) {
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 10,
        background: "repeating-linear-gradient(135deg, #1b1615 0 18px, #211b1a 18px 36px)",
        border: `2px dashed ${color.steel}`,
        borderRadius: "inherit",
        fontFamily: font.mono,
        fontSize: 20,
        color: color.mute,
      }}
    >
      <span style={{ color: color.paper }}>promo/{name}.png</span>
      <span>
        {region.x}, {region.y} · {region.width} × {region.height}
      </span>
    </div>
  );
}
