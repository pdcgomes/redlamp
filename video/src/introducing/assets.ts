import { createContext, useContext } from "react";
import { getStaticFiles, staticFile } from "remotion";

/**
 * What video/scripts/film-assets.mjs rendered with the redlamp CLI, from
 * public/film/renders/manifest.json. Window captures from scripts/capture-promo.sh sit beside
 * them in public/film/captures.
 */
export type Manifest = {
  hero?: {
    name: string;
    bytes: number;
    /** The sidecar package the app saved for the hero's edit. */
    editBytes: number;
    stages: Stage[];
  };
  night?: { name: string; before: string; after: string; look: string };
  cutout?: { name: string; photo: string; subject: string; background: string };
  stocks?: { name: string; original: string; looks: { id: string; file: string; name: string; summary: string }[] };
};

export type Stage =
  | { file: string; step: "import" }
  | { file: string; step: "recipe"; name: string }
  | { file: string; step: "setting"; key: string; value: number };

export const ManifestContext = createContext<Manifest>({});

export function useManifest(): Manifest {
  return useContext(ManifestContext);
}

/** Read once per render, in the composition's calculateMetadata. */
export async function loadManifest(): Promise<Manifest> {
  try {
    const response = await fetch(staticFile("film/renders/manifest.json"));
    return response.ok ? ((await response.json()) as Manifest) : {};
  } catch {
    return {};
  }
}

export function render(file: string): string {
  return staticFile(`film/renders/${file}`);
}

/** A window capture's URL, or null until it's been captured. */
export function capture(name: string): string | null {
  const file = `film/captures/${name}.png`;
  return getStaticFiles().some((f) => f.name === file) ? staticFile(file) : null;
}

/** A step as the History panel words it: "Exposure", "0.00 → +0.75"; "Recipe", "Teal Cinema 2". */
export function stageLabel(stage: Stage): { name: string; before?: string; after?: string } {
  if (stage.step === "import") return { name: "Import" };
  if (stage.step === "recipe") return { name: "Recipe", after: stage.name };
  const decimals = stage.key === "exposure" ? 2 : 0;
  const shown = (v: number) => `${v > 0 ? "+" : ""}${v.toFixed(decimals)}`;
  return { name: stage.key.charAt(0).toUpperCase() + stage.key.slice(1), before: (0).toFixed(decimals), after: shown(stage.value) };
}

/** "67 MB", "4 KB": decimal units, as Finder shows them. */
export function size(bytes: number): string {
  if (bytes >= 1e6) return `${Math.round(bytes / 1e6)} MB`;
  return `${Math.max(1, Math.round(bytes / 1e3))} KB`;
}
