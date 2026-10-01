import { color, font } from "../../theme";
import { type } from "../canvas";
import { Shot, type ShotProps } from "./Shot";

/** The edge and shadow of anything floating over the wall: a card, a window, the drawn recipe card. */
export const floating = "0 0 0 1px rgba(243,238,232,0.12), 0 34px 80px rgba(0,0,0,0.6), 0 10px 24px rgba(0,0,0,0.35)";

type Props = Omit<ShotProps, "radius" | "style"> & {
  /** The caption's first words, in bold paper white. */
  lead?: string;
  caption?: string;
};

/** A crop of the app as a floating card, with a caption under it that leads with a few bold words. */
export function Card({ lead, caption, width, ...shot }: Props) {
  return (
    <div style={{ width, fontFamily: font.family }}>
      <Shot {...shot} width={width} radius={20} style={{ boxShadow: floating }} />
      {lead || caption ? (
        <div style={{ marginTop: 22, fontSize: type.text, lineHeight: 1.2, color: color.mute, textWrap: "pretty" }}>
          {lead ? <span style={{ color: color.paper, fontWeight: 600 }}>{lead} </span> : null}
          {caption}
        </div>
      ) : null}
    </div>
  );
}
