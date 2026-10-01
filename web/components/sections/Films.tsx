import Image from "next/image";
import { FilmTable } from "@/components/sections/FilmTable";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { filmFaithfulness, filmTrademarks } from "@/content/films";

const steps = [
  "Each colour becomes a spectrum.",
  "The film's three layers record it through their own sensitivities.",
  "Characteristic curves turn exposure into dye, with interlayer effects and colour masking.",
  "A negative is printed or scanned the way a lab would; a slide is lit on a light box.",
  "The result is seen through the colour-matching functions of human vision.",
];

export function Films() {
  return (
    <section id="film" className="scroll-mt-24 px-6 py-24">
      <div className="mx-auto max-w-6xl">
        <div className="grid items-end gap-10 lg:grid-cols-[1.1fr_1fr]">
          <SectionHeading eyebrow="Film simulations" title="Eleven film stocks, simulated from their datasheets.">
            Most film presets are tuned by eye. Redlamp&apos;s are physical simulations, built from each
            manufacturer&apos;s own characteristic curves, spectral sensitivities and dye spectra, with the film&apos;s
            grain, halation and bloom.
          </SectionHeading>
          <ol className="flex flex-col gap-2 text-[14px] text-mute">
            {steps.map((step, index) => (
              <li key={step} className="flex gap-3">
                <span className="font-mono text-[12px] leading-[22px] text-dim">{index + 1}</span>
                <span className="leading-relaxed">{step}</span>
              </li>
            ))}
          </ol>
        </div>

        <figure className="mt-14">
          <Image
            src="/synced/images/film-catalog.png"
            alt="The Film Looks window: the open photo in every film, with Portra 400 applied"
            width={1800}
            height={1251}
            sizes="(min-width: 1200px) 1152px, 94vw"
            className="shot h-auto w-full"
          />
          <figcaption className="mt-3 text-[13px] text-dim">
            Window ▸ Film Looks shows the open photo in every film. Hover to preview; click to apply with its grain,
            halation and bloom.
          </figcaption>
        </figure>

        <div className="mt-16">
          <FilmTable />
        </div>

        <div className="mt-14 grid gap-8 lg:grid-cols-[1fr_1fr]">
          <div>
            <h3 className="font-display text-[20px]">How faithful are they?</h3>
            <ul className="mt-4 flex flex-col gap-3 text-[14px] leading-relaxed text-mute">
              {filmFaithfulness.map((note) => (
                <li key={note} className="border-l border-hairline-strong pl-4">
                  {note}
                </li>
              ))}
            </ul>
          </div>
          <figure>
            <Image
              src="/synced/film/overview.jpg"
              alt="Every film look on the same photo, with the original first"
              width={1698}
              height={972}
              sizes="(min-width: 1024px) 560px, 94vw"
              className="h-auto w-full rounded-xl border border-hairline"
            />
            <figcaption className="mt-3 text-[12.5px] text-dim">Every look on one photo, the original first.</figcaption>
          </figure>
        </div>
        <p className="mt-10 text-[12px] leading-relaxed text-dim">{filmTrademarks}</p>
      </div>
    </section>
  );
}
