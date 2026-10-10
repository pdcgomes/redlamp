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
/** A camera mode with camera bench evidence (docs/camera-bench.md), by its tier. */
export type BenchCamera = {
  camera: string;
  mode: string;
  evidence: string;
  photos: number;
  photographers: number;
  problems: string | null;
};
export type CameraMark = "verified" | "tested" | "problem" | "working" | "unconfirmed" | "evaluation" | null;
export type CameraMake = { make: string; models: { name: string; mark: CameraMark }[] };
export type Cameras = {
  libraw: string;
  /** Redlamp's LibRaw fork when the build comes from it rather than from LibRaw itself. */
  fork: string | null;
  verified: VerifiedCamera[];
  bench: BenchCamera[];
  evaluated: EvaluatedCamera[];
  makes: CameraMake[];
};

const MARKS: Record<string, CameraMark> = {
  verified: "verified",
  "tested by photographers": "tested",
  "problem reported": "problem",
  "reported working": "working",
  "problem found once": "unconfirmed",
  "in an evaluation set": "evaluation",
};

function link(cell: string): Link | null {
  const found = cell.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
  return found ? { name: found[1], href: found[2] } : null;
}

export function parseCameras(markdown: string): Cameras {
  const libraw = markdown.match(/^## Supported by LibRaw (\S+)$/m)?.[1];
  if (!libraw) throw new Error('docs/cameras.md has no "## Supported by LibRaw <version>" list: run scripts/camera-list.py --apply');
  const fork = markdown.match(/^\*\*LibRaw:\*\* \S+ \(\[Redlamp's fork\]\(([^)]+)\)\)/m)?.[1] ?? null;
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
  const bench = rows
    .filter((row) => row.section === "Tested with the camera bench")
    .map(({ cells }) => ({
      camera: cells.Camera,
      mode: cells["Raw mode"],
      evidence: cells.Evidence,
      photos: Number(cells.Photos),
      photographers: Number(cells.Photographers),
      problems: cells.Problems && cells.Problems !== "None" ? cells.Problems : null,
    }));
  const evaluated = rows
    .filter((row) => row.section === "In an evaluation set")
    .map(({ cells }) => ({ camera: cells.Camera, set: cells.Set, sample: link(cells.Sample) }));
  const makes: CameraMake[] = [];
  const list = markdown.split(`## Supported by LibRaw ${libraw}`)[1].split("<!-- cameras:end -->")[0];
  for (const line of list.split("\n")) {
    if (line.startsWith("### ")) makes.push({ make: line.slice(4).trim(), models: [] });
    const model = line.match(/^- (.*?)(?: \*\(([a-z ]+)\)\*)?$/);
    if (model && makes.length > 0) {
      const mark = model[2] ? MARKS[model[2]] : undefined;
      // A note in brackets that isn't a mark stays part of the name.
      const name = model[2] && mark === undefined ? `${model[1]} *(${model[2]})*` : model[1];
      makes[makes.length - 1].models.push({ name, mark: mark ?? null });
    }
  }
  if (verified.length === 0 || makes.length === 0) throw new Error("docs/cameras.md: a camera list is empty");
  return { libraw, fork, verified, bench, evaluated, makes };
}
