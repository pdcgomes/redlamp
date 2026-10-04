import { tableRows } from "./tables.ts";

/**
 * The cameras Redlamp reads (docs/cameras.md), whose lists scripts/camera-list.py generates from the
 * decode tests, the sample downloads and LibRaw's own camera list. No file access here, so a client
 * component can share the types; `cameras()` in repo.ts reads the file.
 */

export type Link = { name: string; href: string };
export type VerifiedCamera = {
  camera: string;
  format: string;
  sensor: string;
  resolution: string;
  colourReference: boolean;
  sample: Link | null;
};
export type EvaluatedCamera = { camera: string; set: string; sample: Link | null };
export type CameraMark = "verified" | "evaluation" | null;
export type CameraMake = { make: string; models: { name: string; mark: CameraMark }[] };
export type Cameras = { libraw: string; verified: VerifiedCamera[]; evaluated: EvaluatedCamera[]; makes: CameraMake[] };

function link(cell: string): Link | null {
  const found = cell.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
  return found ? { name: found[1], href: found[2] } : null;
}

export function parseCameras(markdown: string): Cameras {
  const libraw = markdown.match(/^## Supported by LibRaw (\S+)$/m)?.[1];
  if (!libraw) throw new Error('docs/cameras.md has no "## Supported by LibRaw <version>" list: run scripts/camera-list.py --apply');
  const rows = tableRows(markdown, "Camera");
  const verified = rows
    .filter((row) => row.section === "Verified by the decode tests")
    .map(({ cells }) => ({
      camera: cells.Camera,
      format: cells.Format,
      sensor: cells.Sensor,
      resolution: cells.Resolution ?? "",
      colourReference: cells["Colour reference"] === "Yes",
      sample: link(cells.Sample),
    }));
  const evaluated = rows
    .filter((row) => row.section === "In an evaluation set")
    .map(({ cells }) => ({ camera: cells.Camera, set: cells.Set, sample: link(cells.Sample) }));
  const makes: CameraMake[] = [];
  const list = markdown.split(`## Supported by LibRaw ${libraw}`)[1].split("<!-- cameras:end -->")[0];
  for (const line of list.split("\n")) {
    if (line.startsWith("### ")) makes.push({ make: line.slice(4).trim(), models: [] });
    const model = line.match(/^- (.*?)(?: \*\((verified|in an evaluation set)\)\*)?$/);
    if (model && makes.length > 0) {
      const mark = model[2] === "verified" ? "verified" : model[2] ? "evaluation" : null;
      makes[makes.length - 1].models.push({ name: model[1], mark });
    }
  }
  if (verified.length === 0 || makes.length === 0) throw new Error("docs/cameras.md: a camera list is empty");
  return { libraw, verified, evaluated, makes };
}
