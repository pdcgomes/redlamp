import { FilmIcon } from "../../components/Media";
import { margin } from "../canvas";
import { floating } from "../components/Card";
import { Headline } from "../components/Headline";
import { Label } from "../components/Marks";
import { Shot, wholeWindow } from "../components/Shot";
import { StillFrame } from "../components/StillFrame";
import { filmLooksWindow, regions } from "../regions";

const icons = ["portra-400", "cinestill-800t", "vision3-500t-2383", "velvia-50", "kodachrome-64", "tri-x-400"];
const photoWidth = 270;

/** The film catalogue: built from the datasheets, seen in the Film Looks window and on a night street. */
export function Film() {
  return (
    <StillFrame index={3}>
      <div style={{ position: "absolute", left: margin, top: 92, width: 580 }}>
        <Headline
          title="36 film looks, built from the datasheets."
          sub="Each stock's own curves and grain, with halation and bloom."
          size={80}
        />
        <div style={{ marginTop: 44, display: "flex", gap: 12 }}>
          {icons.map((id) => (
            <FilmIcon key={id} id={id} size={56} />
          ))}
        </div>
      </div>
      <div style={{ position: "absolute", left: 744, top: 58 }}>
        <Shot
          name="film-looks"
          region={{ ...wholeWindow, ...filmLooksWindow }}
          captureWidth={filmLooksWindow.width}
          width={620}
          radius={16}
          style={{ boxShadow: floating }}
        />
      </div>
      <div style={{ position: "absolute", left: 704, top: 462, display: "flex", gap: 20 }}>
        <Shot name="film-before" region={regions.photo23} width={photoWidth} radius={18} style={{ boxShadow: floating }}>
          <Label>Before</Label>
        </Shot>
        <Shot name="film-after" region={regions.photo23} width={photoWidth} radius={18} style={{ boxShadow: floating }}>
          <Label>CineStill 800T</Label>
        </Shot>
      </div>
    </StillFrame>
  );
}
