let context: CanvasRenderingContext2D | null = null;

/**
 * The width of a line of Inter, in pixels, for sizing a shape round its words before it's laid
 * out (the canvas draws round the badge and needs its width). Inter is loaded before the first
 * frame renders (src/theme.ts).
 */
export function textWidth(text: string, size: number, weight = 600): number {
  context ??= document.createElement("canvas").getContext("2d");
  if (!context) return text.length * size * 0.55;
  context.font = `${weight} ${size}px Inter`;
  return context.measureText(text).width;
}
