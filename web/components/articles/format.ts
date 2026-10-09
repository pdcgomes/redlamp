import { lstar } from "@/lib/tone";

/** A number with its sign, and a proper minus. */
export function signed(x: number, digits = 1): string {
  const rounded = Number(x.toFixed(digits));
  if (rounded === 0) return (0).toFixed(digits);
  return `${rounded > 0 ? "+" : "−"}${Math.abs(rounded).toFixed(digits)}`;
}

/** A scene value with as many decimals as its size needs. */
export function sceneText(value: number): string {
  if (value >= 100) return value.toFixed(0);
  if (value >= 10) return value.toFixed(1);
  if (value >= 0.1) return value.toFixed(2);
  return value.toFixed(3);
}

/** A display light's L*, or "white" once it's there. */
export function lightnessText(light: number): string {
  if (light >= 0.99995) return "white";
  const l = lstar(light);
  return l >= 99 ? l.toFixed(1) : l.toFixed(0);
}

/** "L* 64", or "white". */
export function lightnessPhrase(light: number): string {
  const text = lightnessText(light);
  return text === "white" ? text : `L* ${text}`;
}

export function percentText(light: number): string {
  return `${(light * 100).toFixed(light < 0.1 ? 2 : 1)}%`;
}
