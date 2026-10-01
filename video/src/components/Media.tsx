import type { CSSProperties } from "react";
import { Img, staticFile } from "remotion";
import { color } from "../theme";

export type Look = "original" | "portra-400" | "velvia-50" | "cinestill-800t" | "vision3-500t-2383" | "tri-x-400";

/** A CC0 landscape developed by Redlamp itself (scripts/render-photos.sh). */
export function Photo({ look = "original", style }: { look?: Look; style?: CSSProperties }) {
  return (
    <Img
      src={staticFile(`photos/${look}.jpg`)}
      style={{ width: "100%", height: "100%", objectFit: "cover", objectPosition: "50% 45%", transform: "scale(1.06)", ...style }}
    />
  );
}

export function Lockup({ width }: { width: number }) {
  return <Img src={staticFile("synced/brand/logo/redlamp-lockup.svg")} style={{ width, height: "auto" }} />;
}

export function FilmIcon({ id, size }: { id: string; size: number }) {
  return <Img src={staticFile(`synced/film/icon-${id}.png`)} style={{ width: size, height: size }} />;
}

/** A floating piece of glass chrome, as macOS 26 draws it. */
export const glass: CSSProperties = {
  background: "linear-gradient(180deg, rgba(44,36,33,0.78), rgba(26,20,19,0.78))",
  border: `1px solid ${color.hairline}`,
  boxShadow: "inset 0 1px 0 rgba(255,255,255,0.06), 0 30px 80px rgba(0,0,0,0.55)",
  borderRadius: 22,
};
