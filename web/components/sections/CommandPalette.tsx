import Image from "next/image";
import { Inline } from "@/components/ui/Inline";
import { LightboxGroup, ShotButton } from "@/components/ui/Lightbox";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { commandPalette, paletteSteps } from "@/content/features";

const closeUps = paletteSteps.map((step) => ({ ...step.image, caption: step.title }));

function Keys({ keys }: { keys: string[] }) {
  return (
    <span className="flex shrink-0 gap-1.5">
      {keys.map((key) => (
        <kbd
          key={key}
          className="rounded-md border border-hairline-strong bg-bakelite-hi px-1.5 py-0.5 font-sans text-[12px] leading-[18px] font-medium text-ring shadow-[inset_0_-1px_0_rgb(0_0_0/0.4)]"
        >
          {key}
        </kbd>
      ))}
    </span>
  );
}

/** The palette's interaction model in four steps, each on a close-up of the palette at work. */
export function CommandPalette() {
  return (
    <section id="command-palette" className="scroll-mt-24 px-6 py-24">
      <div className="mx-auto max-w-6xl">
        <SectionHeading eyebrow={commandPalette.eyebrow} title={commandPalette.title}>
          {commandPalette.body}
        </SectionHeading>
        <LightboxGroup shots={closeUps}>
          <ol className="mt-14 grid gap-x-10 gap-y-14 md:grid-cols-2">
            {paletteSteps.map((step, index) => (
              <li key={step.title}>
                <ShotButton index={index} label={step.image.alt}>
                  <Image
                    src={step.image.src}
                    alt={step.image.alt}
                    width={step.image.width}
                    height={step.image.height}
                    sizes="(min-width: 768px) 556px, 94vw"
                    className="shot h-auto w-full rounded-xl"
                  />
                </ShotButton>
                <div className="mt-6 flex flex-wrap items-center justify-between gap-3">
                  <h3 className="font-display text-[20px] text-paper">
                    <span className="mr-3 text-dim">{index + 1}</span>
                    {step.title}
                  </h3>
                  <Keys keys={step.keys} />
                </div>
                <p className="mt-2 text-[15px] leading-relaxed text-mute">
                  <Inline md={step.body} />
                </p>
              </li>
            ))}
          </ol>
        </LightboxGroup>
        <p className="mt-14 text-[14px] text-dim">{commandPalette.footer}</p>
      </div>
    </section>
  );
}
