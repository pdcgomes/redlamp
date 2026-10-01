import { FilmIcon } from "../../components/Media";
import { color, font } from "../../theme";
import { margin, type } from "../canvas";
import { floating } from "../components/Card";
import { Headline } from "../components/Headline";
import { Shot, wholeWindow } from "../components/Shot";
import { StillFrame } from "../components/StillFrame";
import { filmLooksWindow, regions } from "../regions";

const icons = ["portra-400", "cinestill-800t", "vision3-500t-2383", "velvia-50", "kodachrome-64", "tri-x-400"];

/** The film catalogue: built from the datasheets, seen in the Film Looks window and on a night street. */
export function Film() {
  const split = 0.5;
  const before = { width: 640, height: 640 * (regions.photo32.height / regions.photo32.width) };
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
      <div
        style={{
          position: "absolute",
          left: 630,
          top: 470,
          ...before,
          borderRadius: 20,
          overflow: "hidden",
          boxShadow: floating,
        }}
      >
        <Shot name="film-before" region={regions.photo32} width={before.width} />
        <div style={{ position: "absolute", inset: 0, clipPath: `inset(0 0 0 ${split * 100}%)` }}>
          <Shot name="film-after" region={regions.photo32} width={before.width} />
        </div>
        <div style={{ position: "absolute", top: 0, bottom: 0, left: `${split * 100}%`, width: 3, background: color.paper }} />
        {[
          { label: "Before", side: "left" as const },
          { label: "CineStill 800T", side: "right" as const },
        ].map(({ label, side }) => (
          <div
            key={label}
            style={{
              position: "absolute",
              top: 18,
              [side]: 18,
              padding: "6px 14px",
              borderRadius: 999,
              background: "rgba(10,7,7,0.62)",
              fontFamily: font.family,
              fontSize: type.small + 4,
              color: color.paper,
            }}
          >
            {label}
          </div>
        ))}
      </div>
    </StillFrame>
  );
}
