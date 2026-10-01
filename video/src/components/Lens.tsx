import { useId } from "react";
import { color } from "../theme";

type Props = {
  size: number;
  /** 0 is a cold lamp, 1 fully lit. */
  glow?: number;
  /** Draw the app icon's tile and wall behind the lamp. */
  tile?: boolean;
};

/**
 * The app icon's safelight (apps/RedlampMac/Resources/AppIcon.icon), drawn in SVG so the
 * filament can warm up: a domed ruby lens with Fresnel rings in a steel bezel with three screws.
 */
export function Lens({ size, glow = 1, tile = false }: Props) {
  const id = useId().replace(/:/g, "");
  const g = Math.max(0, Math.min(1, glow));
  const screws = [-90, 30, 150].map((deg) => {
    const a = (deg * Math.PI) / 180;
    return [50 + 30.2 * Math.cos(a), 47 + 30.2 * Math.sin(a)];
  });
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" style={{ overflow: "visible", display: "block" }}>
      <defs>
        <linearGradient id={`${id}-wall`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={color.wallTop} />
          <stop offset="1" stopColor={color.wall} />
        </linearGradient>
        <radialGradient id={`${id}-amb`} cx="50" cy="47" r="58" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor={color.safelight} stopOpacity={0.45 * g} />
          <stop offset="1" stopColor={color.safelight} stopOpacity="0" />
        </radialGradient>
        <linearGradient id={`${id}-bezel`} x1="0" y1="14" x2="0" y2="80" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#57504e" />
          <stop offset="0.5" stopColor="#221c1a" />
          <stop offset="1" stopColor="#0b0908" />
        </linearGradient>
        <linearGradient id={`${id}-step`} x1="0" y1="19.5" x2="0" y2="74.5" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#0b0908" />
          <stop offset="1" stopColor="#57504e" stopOpacity="0.8" />
        </linearGradient>
        <linearGradient id={`${id}-rim`} x1="0" y1="14.5" x2="0" y2="79.5" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#fff" stopOpacity="0.5" />
          <stop offset="0.55" stopColor="#fff" stopOpacity="0" />
        </linearGradient>
        <radialGradient id={`${id}-ruby`} cx="50" cy="44" r="28" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor={mix("#5a1a12", color.filament, g)} />
          <stop offset="0.38" stopColor={mix("#4a1510", color.ruby, g)} />
          <stop offset="0.8" stopColor={mix("#2a0b08", color.safelightDeep, g)} />
          <stop offset="1" stopColor={color.rubyShadow} />
        </radialGradient>
        <radialGradient id={`${id}-fil`} cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor={color.filament} stopOpacity={0.65 * g} />
          <stop offset="0.45" stopColor={color.filament} stopOpacity={0.3 * g} />
          <stop offset="1" stopColor={color.filament} stopOpacity="0" />
        </radialGradient>
        <radialGradient id={`${id}-sheen`} cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#fff" stopOpacity="0.32" />
          <stop offset="0.7" stopColor="#fff" stopOpacity="0.2" />
          <stop offset="1" stopColor="#fff" stopOpacity="0" />
        </radialGradient>
        <radialGradient id={`${id}-halo`} cx="50" cy="47" r="80" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor={color.safelight} stopOpacity={0.5 * g} />
          <stop offset="0.35" stopColor={color.safelight} stopOpacity={0.14 * g} />
          <stop offset="1" stopColor={color.safelight} stopOpacity="0" />
        </radialGradient>
        <clipPath id={`${id}-tile`}>
          <rect width="100" height="100" rx="22.5" />
        </clipPath>
      </defs>
      {tile ? (
        <g clipPath={`url(#${id}-tile)`}>
          <rect width="100" height="100" fill={`url(#${id}-wall)`} />
          <rect width="100" height="100" fill={`url(#${id}-amb)`} />
        </g>
      ) : (
        <circle cx="50" cy="47" r="80" fill={`url(#${id}-halo)`} />
      )}
      <circle cx="50" cy="50" r="34" fill="#000" opacity="0.45" />
      <circle cx="50" cy="47" r="33" fill={`url(#${id}-bezel)`} />
      <circle cx="50" cy="47" r="32.5" fill="none" stroke={`url(#${id}-rim)`} strokeWidth="0.9" />
      <circle cx="50" cy="47" r="27.5" fill={`url(#${id}-step)`} />
      {screws.map(([x, y]) => (
        <g key={`${x}`}>
          <circle cx={x} cy={y} r="1.35" fill="#6a625f" />
          <line x1={x - 0.88} y1={y + 0.41} x2={x + 0.88} y2={y - 0.41} stroke="#0b0908" strokeWidth="0.45" />
        </g>
      ))}
      <circle cx="50" cy="47" r="25" fill={`url(#${id}-ruby)`} />
      <g fill="none" stroke={color.filament} strokeOpacity={0.05 + 0.08 * g} strokeWidth="0.6">
        {[8, 12.5, 17, 21].map((r) => (
          <circle key={r} cx="50" cy="47" r={r} />
        ))}
      </g>
      <ellipse cx="50" cy="48" rx="12" ry="9.5" fill={`url(#${id}-fil)`} />
      <circle cx="50" cy="47" r="24.4" fill="none" stroke={color.rubyShadow} strokeWidth="1.2" strokeOpacity="0.7" />
      <ellipse cx="41" cy="36" rx="12" ry="6" transform="rotate(-32 41 36)" fill={`url(#${id}-sheen)`} />
      <circle cx="38.5" cy="34.5" r="1.4" fill="#fff" fillOpacity="0.85" />
      {tile ? (
        <rect x="0.5" y="0.5" width="99" height="99" rx="22" fill="none" stroke="rgba(255,255,255,0.12)" />
      ) : null}
    </svg>
  );
}

function mix(a: string, b: string, t: number): string {
  const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16));
  const out = pa.map((v, i) => Math.round(v + (pb[i] - v) * t));
  return `rgb(${out.join(",")})`;
}
