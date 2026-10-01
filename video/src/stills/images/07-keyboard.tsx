import { glass } from "../../components/Media";
import { color, font } from "../../theme";
import { margin } from "../canvas";
import { floating } from "../components/Card";
import { Headline, Typed } from "../components/Headline";
import { Shot } from "../components/Shot";
import { StillFrame } from "../components/StillFrame";

/** The command palette: every action and slider from the keyboard. Waits for a release that has it. */
export function Keyboard() {
  return (
    <StillFrame index={6}>
      <div style={{ position: "absolute", left: margin, top: 92, width: 580 }}>
        <Headline
          title="Every control from the keyboard."
          sub={
            <>
              ⌘K finds any action or slider. Typing <Typed>exposure 0.7</Typed> sets it.
            </>
          }
        />
        <div style={{ marginTop: 56, display: "flex", gap: 20 }}>
          <Key label="⌘" />
          <Key label="K" />
        </div>
      </div>
      <div style={{ position: "absolute", left: 690, top: 206 }}>
        <Shot
          name="palette"
          region={{ x: 400, y: 50, width: 800, height: 540 }}
          width={680}
          radius={20}
          style={{ boxShadow: floating }}
        />
      </div>
    </StillFrame>
  );
}

function Key({ label }: { label: string }) {
  return (
    <div
      style={{
        ...glass,
        width: 128,
        height: 128,
        borderRadius: 26,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: font.family,
        fontSize: 64,
        fontWeight: 500,
        color: color.paper,
        boxShadow: "inset 0 1px 0 rgba(255,255,255,0.08), inset 0 -6px 0 rgba(0,0,0,0.35), 0 20px 40px rgba(0,0,0,0.5)",
      }}
    >
      {label}
    </div>
  );
}
