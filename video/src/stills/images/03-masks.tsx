import { margin } from "../canvas";
import { floating } from "../components/Card";
import { Headline } from "../components/Headline";
import { Chip, Label } from "../components/Marks";
import { Shot } from "../components/Shot";
import { StillFrame } from "../components/StillFrame";

const kinds = ["Subject", "Sky", "Background", "People", "Face skin", "Eyes", "Lips", "Teeth"];

/** On-device AI masks: what they find, on real photos, with the panel that holds them. */
export function Masks() {
  return (
    <StillFrame index={2}>
      <div style={{ position: "absolute", left: margin, top: 92, width: 520 }}>
        <Headline
          title="Masks that know what's in the photo."
          sub="Subject, Sky, Background and People, down to eyes and teeth. All on your Mac."
          size={80}
        />
        <div style={{ marginTop: 40, display: "flex", flexWrap: "wrap", gap: 14 }}>
          {kinds.map((kind) => (
            <Chip key={kind} size={34}>
              {kind}
            </Chip>
          ))}
        </div>
      </div>
      {/* People shown as Image on Black, beside the Masks panel that holds the mask. */}
      <div style={{ position: "absolute", left: 646, top: 64 }}>
        <Shot
          name="masks-people"
          region={{ x: 457.5, y: 150, width: 1140, height: 640 }}
          width={700}
          radius={20}
          style={{ boxShadow: floating }}
        >
          <Label>People</Label>
        </Shot>
      </div>
      <div style={{ position: "absolute", left: 646, top: 478 }}>
        <Shot
          name="masks-face"
          region={{ x: 622, y: 398, width: 400, height: 400 }}
          width={340}
          radius={18}
          style={{ boxShadow: floating }}
        >
          <Label>Face skin</Label>
        </Shot>
      </div>
      <div style={{ position: "absolute", left: 1006, top: 478 }}>
        <Shot
          name="masks-subject"
          region={{ x: 457.5, y: 200, width: 627, height: 627 }}
          width={340}
          radius={18}
          style={{ boxShadow: floating }}
        >
          <Label>Subject</Label>
        </Shot>
      </div>
    </StillFrame>
  );
}
