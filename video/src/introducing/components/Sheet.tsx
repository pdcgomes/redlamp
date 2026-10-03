import type { CSSProperties, ReactNode } from "react";
import { Img } from "remotion";
import { font, neutral, type as typeScale, useShape } from "../style";
import { facing, type View } from "./Space";

type SheetProps = {
  src: string;
  width: number;
  height: number;
  /** The sheet's centre in the world. */
  x?: number;
  y?: number;
  z?: number;
  /** Extra turn for this sheet alone, in degrees. */
  ry?: number;
  opacity?: number;
  /** Darkens the sheet, for the ones further back. */
  shade?: number;
  /** A greyscale matte (white keeps) that cuts the sheet out, as Redlamp's masks are written. */
  mask?: string;
  /** A soft light around a cut-out, 0 to 1. */
  glow?: number;
  /** The hairline round the sheet's edge, 0 to 1. */
  edge?: number;
  radius?: number;
  children?: ReactNode;
};

/** One sheet of an onion-skin stack: a photo standing in the world, facing the camera's start. */
export function Sheet({
  src,
  width,
  height,
  x = 0,
  y = 0,
  z = 0,
  ry = 0,
  opacity = 1,
  shade = 0,
  mask,
  glow = 0,
  edge = 1,
  radius = 6,
  children,
}: SheetProps) {
  const masked: CSSProperties = mask
    ? {
        maskImage: `url(${mask})`,
        WebkitMaskImage: `url(${mask})`,
        maskMode: "luminance",
        maskSize: "100% 100%",
        WebkitMaskSize: "100% 100%",
      }
    : {};
  return (
    <div
      style={{
        position: "absolute",
        left: x - width / 2,
        top: y - height / 2,
        width,
        height,
        transformStyle: "preserve-3d",
        transform: `translateZ(${z}px) rotateY(${ry}deg)`,
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: 0,
          opacity,
          filter: glow > 0 ? `drop-shadow(0 0 ${18 * glow}px rgba(255,255,255,${0.32 * glow}))` : undefined,
        }}
      >
        <div style={{ position: "absolute", inset: 0, borderRadius: radius, overflow: "hidden", ...masked }}>
          <Img src={src} style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }} />
          {shade > 0 ? <div style={{ position: "absolute", inset: 0, background: `rgba(6,6,7,${shade})` }} /> : null}
        </div>
        {edge <= 0 ? null : (
          <div
            style={{
              position: "absolute",
              inset: 0,
              borderRadius: radius,
              boxShadow: `inset 0 0 0 1px rgba(255,255,255,${0.16 * edge})`,
            }}
          />
        )}
      </div>
      {children}
    </div>
  );
}

type TagProps = {
  view: View;
  /** Where on the sheet the tag hangs, in pixels from the sheet's top left, and how far in front. */
  x: number;
  y: number;
  z?: number;
  /** Which way the tag extends from its anchor. */
  anchor?: "left" | "right" | "center";
  icon?: ReactNode;
  title: string;
  detail?: string;
  opacity?: number;
  style?: CSSProperties;
};

/** A label in the app's History style, hung on a sheet but always facing the viewer. */
export function Tag({ view, x, y, z = 2, anchor = "left", icon, title, detail, opacity = 1, style }: TagProps) {
  const { shape } = useShape();
  const size = typeScale[shape].label;
  const shift = anchor === "left" ? "0%" : anchor === "right" ? "-100%" : "-50%";
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transformStyle: "preserve-3d",
        transform: `translateZ(${z}px) ${facing(view)}`,
        opacity,
      }}
    >
      <div
        style={{
          transform: `translate(${shift}, -50%)`,
          display: "flex",
          alignItems: "center",
          gap: size * 0.5,
          padding: `${size * 0.42}px ${size * 0.7}px`,
          borderRadius: size * 0.55,
          background: "rgba(22,22,24,0.86)",
          boxShadow: `inset 0 0 0 1px ${neutral.hairline}, 0 12px 30px rgba(0,0,0,0.35)`,
          whiteSpace: "nowrap",
          fontFamily: font.family,
          fontSize: size,
          ...style,
        }}
      >
        {icon ? <span style={{ display: "flex", color: neutral.label }}>{icon}</span> : null}
        <span style={{ ...font.text, fontWeight: 560, color: "rgba(255,255,255,0.9)" }}>{title}</span>
        {detail ? <span style={{ ...font.text, color: neutral.secondary }}>{detail}</span> : null}
      </div>
    </div>
  );
}
