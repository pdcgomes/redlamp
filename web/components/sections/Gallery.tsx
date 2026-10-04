"use client";

import Image from "next/image";
import { useState } from "react";
import { Lightbox } from "@/components/ui/Lightbox";
import type { Shot } from "@/content/features";

export function Gallery({ shots }: { shots: Shot[] }) {
  const [open, setOpen] = useState<number | null>(null);

  return (
    <section id="gallery" aria-labelledby="gallery-title" className="px-6 pb-24">
      <div className="mx-auto max-w-6xl">
        <h2 id="gallery-title" className="font-display text-[22px]">
          More of the app
        </h2>
        <div className="mt-6 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
          {shots.map((shot, index) => (
            <button
              key={shot.src}
              onClick={() => setOpen(index)}
              aria-haspopup="dialog"
              className="group cursor-zoom-in text-left"
            >
              <Image
                src={shot.src}
                alt={shot.alt}
                width={shot.width}
                height={shot.height}
                sizes="(min-width: 1024px) 280px, (min-width: 640px) 46vw, 94vw"
                className="h-auto w-full rounded-lg border border-hairline transition-transform duration-300 group-hover:-translate-y-0.5"
              />
              <span className="mt-2 block text-[12.5px] leading-snug text-dim group-hover:text-mute">{shot.caption}</span>
            </button>
          ))}
        </div>
      </div>
      <Lightbox shots={shots} index={open} onIndex={setOpen} onClose={() => setOpen(null)} />
    </section>
  );
}
