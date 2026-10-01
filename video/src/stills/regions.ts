import type { Region } from "./components/Shot";

/**
 * Where things sit in a 1600 × 1000 capture of the editor (scripts/capture-promo.sh), in window
 * points. Measured on the captures; panels keep their width at any window size.
 */
export const regions = {
  /** A 4:3 photo at Fit, between the two panels. */
  photo43: { x: 266, y: 143.5, width: 1010, height: 757 },
  /** A 3:2 photo at Fit. */
  photo32: { x: 266, y: 185.5, width: 1010, height: 673 },
  /** The right-hand panel column: histogram, tool strip and the Develop panels. */
  inspector: { x: 1284, y: 0, width: 311, height: 1000 },
  histogram: { x: 1290, y: 36, width: 300, height: 140 },
  /** Basic's Tone and Presence groups, from Exposure to Saturation. */
  basicTone: { x: 1284, y: 418, width: 311, height: 318 },
  /** The Masks list, the selected mask's components and Add, Subtract and Intersect. */
  masks: { x: 1284, y: 240, width: 311, height: 186 },
  /** Effects' Grain, Halation and Bloom groups, with only Effects open. */
  filmEffects: { x: 1284, y: 680, width: 311, height: 268 },
  /** The Keyboard Shortcuts overlay. */
  shortcuts: { x: 260, y: 166, width: 1080, height: 718 },
  /** The command palette, open over the photo. */
  palette: { x: 490, y: 64, width: 620, height: 424 },
} satisfies Record<string, Region>;

/** The Effects panel's Camera Recipe group, in the 1600 × 1410 `fujifilm-effects` capture. */
export const cameraRecipe: Region = { x: 1284, y: 1192, width: 311, height: 142 };

/** The Film Looks window, captured on its own at 1180 × 820 points. */
export const filmLooksWindow = { width: 1180, height: 820 } as const;
