import { margin } from "../canvas";
import { Card } from "../components/Card";
import { Headline } from "../components/Headline";
import { StillFrame } from "../components/StillFrame";
import { regions } from "../regions";

const steps = [
  { name: "stack-banner", lead: "Detected.", caption: "Merge is one click." },
  { name: "stack-depth", lead: "Merged", caption: "with a depth map." },
  { name: "stack-merged", lead: "Still a raw.", caption: "Every slider works." },
];

/** Focus stacking: detected, merged, and developed like any raw. */
export function Stacking() {
  return (
    <StillFrame index={5}>
      <Headline
        title="Focus stacking, found for you."
        sub="Redlamp finds the sequence and merges it. The result develops like a raw."
        style={{ position: "absolute", left: margin, top: 80, width: 1000 }}
      />
      <div style={{ position: "absolute", left: margin, top: 446, display: "flex", gap: 36 }}>
        {steps.map((step) => (
          <Card key={step.name} name={step.name} region={regions.photo32} width={392} lead={step.lead} caption={step.caption} />
        ))}
      </div>
    </StillFrame>
  );
}
