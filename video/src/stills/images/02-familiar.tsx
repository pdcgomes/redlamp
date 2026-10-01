import { margin } from "../canvas";
import { Card } from "../components/Card";
import { Headline } from "../components/Headline";
import { StillFrame } from "../components/StillFrame";

const cardWidth = 588;

/** Lightroom users already know the panels, the sliders and the keys. */
export function Familiar() {
  return (
    <StillFrame index={1}>
      <Headline
        title="Nothing to relearn."
        sub="Lightroom's panel order, slider names and ranges, and Lightroom Classic's shortcuts."
        style={{ position: "absolute", left: margin, top: 80, width: 1100 }}
      />
      <div style={{ position: "absolute", left: margin, top: 352, display: "flex", gap: 72 }}>
        <Card
          name="panels"
          region={{ x: 1284, y: 414, width: 311, height: 170 }}
          width={cardWidth}
          lead="The same sliders,"
          caption="in the same order."
        />
        <Card
          name="shortcuts"
          region={{ x: 262, y: 168, width: 540, height: 295 }}
          width={cardWidth}
          lead="⌘/"
          caption="lists all 83 of Lightroom Classic's shortcuts."
        />
      </div>
    </StillFrame>
  );
}
