import { margin } from "../canvas";
import { floating } from "../components/Card";
import { Headline } from "../components/Headline";
import { Chip } from "../components/Marks";
import { Shot } from "../components/Shot";
import { StillFrame } from "../components/StillFrame";
import { regions } from "../regions";

const kinds = ["Subject", "Sky", "Background", "People", "Face skin", "Eyes", "Lips", "Teeth"];

/** On-device AI masks: what they find, on real photos, with the panel that holds them. */
export function Masks() {
  return (
    <StillFrame index={2}>
      <div style={{ position: "absolute", left: margin, top: 92, width: 540 }}>
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
      <div style={{ position: "absolute", left: 690, top: 70 }}>
        <Shot name="masks-sky" region={regions.photo43} width={660} radius={20} style={{ boxShadow: floating }} />
      </div>
      <div style={{ position: "absolute", left: 1010, top: 470 }}>
        <Shot name="masks-people" region={regions.photo32} width={400} radius={20} style={{ boxShadow: floating }} />
      </div>
      <div style={{ position: "absolute", left: 640, top: 560 }}>
        <Shot name="masks-sky" region={regions.masks} width={420} radius={20} style={{ boxShadow: floating }} />
      </div>
    </StillFrame>
  );
}
