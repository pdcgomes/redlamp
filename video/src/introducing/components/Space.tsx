import type { ReactNode } from "react";
import { AbsoluteFill } from "remotion";

export type View = {
  /** Degrees: tilt (positive looks down on the subject), turn, roll. */
  rx?: number;
  ry?: number;
  rz?: number;
  /** Pixels, after the turn: the subject's offset from the frame's centre and its distance. */
  x?: number;
  y?: number;
  z?: number;
  scale?: number;
};

/**
 * A camera looking at the frame's centre. Children are placed in a world whose origin is that
 * centre; nothing between here and the planes may flatten 3D (filters, opacity, overflow).
 */
export function Camera({ perspective = 2600, view, children }: { perspective?: number; view: View; children: ReactNode }) {
  const { rx = 0, ry = 0, rz = 0, x = 0, y = 0, z = 0, scale = 1 } = view;
  return (
    <AbsoluteFill style={{ perspective, perspectiveOrigin: "50% 50%" }}>
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: "50%",
          transformStyle: "preserve-3d",
          transform: `translate3d(${x}px, ${y}px, ${z}px) rotateX(${-rx}deg) rotateY(${ry}deg) rotateZ(${rz}deg) scale3d(${scale}, ${scale}, ${scale})`,
        }}
      >
        {children}
      </div>
    </AbsoluteFill>
  );
}

/**
 * Where a point in the camera's world lands in the frame, in pixels from the top left: the same
 * transforms `Camera` applies (scale, roll, turn, tilt, then the offset), then its perspective.
 */
export function project(view: View, perspective: number, frame: { width: number; height: number }, point: [number, number, number]) {
  const { rx = 0, ry = 0, rz = 0, x = 0, y = 0, z = 0, scale = 1 } = view;
  const rad = Math.PI / 180;
  let [px, py, pz] = point.map((v) => v * scale);
  [px, py] = [px * Math.cos(rz * rad) - py * Math.sin(rz * rad), px * Math.sin(rz * rad) + py * Math.cos(rz * rad)];
  [px, pz] = [px * Math.cos(ry * rad) + pz * Math.sin(ry * rad), -px * Math.sin(ry * rad) + pz * Math.cos(ry * rad)];
  [py, pz] = [py * Math.cos(-rx * rad) - pz * Math.sin(-rx * rad), py * Math.sin(-rx * rad) + pz * Math.cos(-rx * rad)];
  const k = perspective / (perspective - (pz + z));
  return { x: frame.width / 2 + (px + x) * k, y: frame.height / 2 + (py + y) * k };
}

/** Undoes a camera's turn, so a label faces the viewer wherever its sheet is. */
export function facing(view: View): string {
  return `rotateZ(${-(view.rz ?? 0)}deg) rotateY(${-(view.ry ?? 0)}deg) rotateX(${view.rx ?? 0}deg)`;
}