import type { CSSProperties } from "react";
import { Img, staticFile } from "remotion";
import { color } from "../theme";

export function Lockup({ width }: { width: number }) {
  return <Img src={staticFile("synced/brand/logo/redlamp-lockup.svg")} style={{ width, height: "auto", display: "block" }} />;
}

export function FilmIcon({ id, size }: { id: string; size: number }) {
  return <Img src={staticFile(`synced/film/icon-${id}.png`)} style={{ width: size, height: size, display: "block" }} />;
}

/** A floating piece of glass chrome, as macOS 26 draws it. */
export const glass: CSSProperties = {
  background: "linear-gradient(180deg, rgba(44,36,33,0.86), rgba(26,20,19,0.86))",
  border: `1px solid ${color.hairline}`,
  boxShadow: "inset 0 1px 0 rgba(255,255,255,0.06), 0 30px 80px rgba(0,0,0,0.55)",
  borderRadius: 22,
};
