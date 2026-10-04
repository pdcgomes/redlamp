import { Inline } from "@/components/ui/Inline";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { aiDisclosure } from "@/content/ai";

export function AIDisclosure() {
  const { eyebrow, title, intro, items, footnote } = aiDisclosure;
  return (
    <section id="ai" className="scroll-mt-24 px-6 py-24">
      <div className="mx-auto max-w-6xl">
        <SectionHeading eyebrow={eyebrow} title={title}>
          <Inline md={intro} />
        </SectionHeading>
        <div className="mt-10 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {items.map((item) => (
            <div key={item.title} className="surface p-6">
              <h3 className="font-display text-[18px] text-paper">{item.title}</h3>
              <p className="mt-2 text-[14px] leading-relaxed text-mute">
                <Inline md={item.body} />
              </p>
            </div>
          ))}
        </div>
        <p className="mt-6 max-w-3xl text-[12.5px] leading-relaxed text-dim">{footnote}</p>
      </div>
    </section>
  );
}
