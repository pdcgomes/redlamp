/** Line icons in the manner of the SF Symbols the app's History and panels use. */
type Props = { size: number };

const stroke = { fill: "none", stroke: "currentColor", strokeWidth: 1.6, strokeLinecap: "round", strokeLinejoin: "round" } as const;

/** Import: a tray with an arrow into it. */
export function ImportIcon({ size }: Props) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <path d="M12 3.5v10M8 9.8l4 3.9 4-3.9" {...stroke} />
      <path d="M4.5 14.5v3.2a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-3.2" {...stroke} />
    </svg>
  );
}

/** A recipe: the wand and sparkle. */
export function RecipeIcon({ size }: Props) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <path d="M5 19 15.5 8.5M14 6.8l3.2 3.2" {...stroke} />
      <path d="M18.5 3.5v3M17 5h3M7.5 4.5v2M6.5 5.5h2M19 12.5v2M18 13.5h2" {...stroke} />
    </svg>
  );
}

/** A slider setting. */
export function SliderIcon({ size }: Props) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <path d="M4 7h9M17 7h3M4 17h3M11 17h9" {...stroke} />
      <circle cx="15" cy="7" r="2" {...stroke} />
      <circle cx="9" cy="17" r="2" {...stroke} />
    </svg>
  );
}

/** A person, for People masks. */
export function PersonIcon({ size }: Props) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <circle cx="12" cy="8" r="3.4" {...stroke} />
      <path d="M5.5 19.5c.8-3.6 3.4-5.6 6.5-5.6s5.7 2 6.5 5.6" {...stroke} />
    </svg>
  );
}

/** A landscape frame, for Background. */
export function BackgroundIcon({ size }: Props) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <rect x="3.5" y="5" width="17" height="14" rx="2" {...stroke} />
      <path d="m4 16 4.5-4.5 3.5 3.5 2.5-2.5L20 17.5" {...stroke} />
    </svg>
  );
}

/** A document, for the sidecar. */
export function DocumentIcon({ size }: Props) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <path d="M7 3.5h6.5L18 8v11a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 19V5a1.5 1.5 0 0 1 1-1.5Z" {...stroke} />
      <path d="M13.5 3.5V8H18M9 12.5h6M9 15.5h6" {...stroke} />
    </svg>
  );
}

/** A raw file: the photo itself. */
export function PhotoIcon({ size }: Props) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <rect x="4" y="3.5" width="16" height="17" rx="2" {...stroke} />
      <circle cx="9.5" cy="9" r="1.6" {...stroke} />
      <path d="m4.5 17 4.5-4.2 3 2.7 2.6-2.3 4.9 4.3" {...stroke} />
    </svg>
  );
}
