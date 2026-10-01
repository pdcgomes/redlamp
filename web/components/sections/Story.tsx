import { Mark } from "@/components/brand/Logo";
import { principles } from "@/content/features";

export function Story() {
  return (
    <section id="why" className="px-6 py-24">
      <div className="mx-auto grid max-w-6xl items-start gap-12 lg:grid-cols-[1.1fr_1fr]">
        <div>
          <p className="eyebrow">Why Redlamp</p>
          <blockquote className="font-display mt-4 text-[clamp(1.8rem,3.6vw,2.7rem)] leading-[1.15] text-paper">
            A red lamp is the darkroom safelight: the one light you can work by without fogging the paper.
          </blockquote>
          <div className="mt-6 flex items-center gap-3 text-[14px] text-mute">
            <Mark className="size-6" />
            You can see and shape your photo freely, and the original is never harmed.
          </div>
        </div>
        <div className="flex flex-col gap-5 text-[17px] leading-relaxed text-mute">
          <p>
            Lightroom defined how millions of photographers edit, but it&apos;s a cross-platform application that
            doesn&apos;t feel at home on a Mac, and it&apos;s tied to a subscription and a cloud.
          </p>
          <p>
            Redlamp keeps the workflow photographers already know, including the panel layout, slider names and
            ranges, and keyboard shortcuts, and rebuilds everything underneath as a native, GPU-first, open-source
            application.
          </p>
          <p className="text-paper">
            <strong className="font-semibold">Redlamp is an editor, not a catalog.</strong>{" "}
            <span className="text-mute">
              It opens folders of photos and keeps your edits in small sidecar files right next to them.
            </span>
          </p>
        </div>
      </div>
    </section>
  );
}

export function Principles() {
  return (
    <section id="principles" className="px-6 pb-24">
      <div className="mx-auto grid max-w-6xl gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {principles.map((principle, index) => (
          <div key={principle.title} className="surface p-6">
            <p className="font-mono text-[12px] text-dim">{String(index + 1).padStart(2, "0")}</p>
            <h3 className="font-display mt-3 text-[18px] text-paper">{principle.title}</h3>
            <p className="mt-2 text-[14px] leading-relaxed text-mute">{principle.body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
