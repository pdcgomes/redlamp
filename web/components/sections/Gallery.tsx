"use client";

import Image from "next/image";
import { useEffect, useRef, useState } from "react";
import type { Shot } from "@/content/features";

export function Gallery({ shots }: { shots: Shot[] }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [open, setOpen] = useState<Shot | null>(null);

  useEffect(() => {
    if (open) dialog.current?.showModal();
  }, [open]);

  return (
    <section id="gallery" aria-labelledby="gallery-title" className="px-6 pb-24">
      <div className="mx-auto max-w-6xl">
        <h2 id="gallery-title" className="font-display text-[22px]">
          More of the app
        </h2>
        <div className="mt-6 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
          {shots.map((shot) => (
            <button key={shot.src} onClick={() => setOpen(shot)} className="group text-left">
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
      <dialog
        ref={dialog}
        onClose={() => setOpen(null)}
        onClick={(event) => {
          if (event.target === dialog.current) dialog.current?.close();
        }}
        className="m-auto max-h-[92vh] w-[min(96vw,1500px)] bg-transparent p-0 backdrop:bg-wall/85 backdrop:backdrop-blur-sm"
      >
        {open ? (
          <figure className="flex flex-col items-center gap-3">
            <Image
              src={open.src}
              alt={open.alt}
              width={open.width}
              height={open.height}
              sizes="96vw"
              className="shot h-auto max-h-[84vh] w-auto"
            />
            <figcaption className="flex items-center gap-4 text-[13px] text-mute">
              {open.caption}
              <button onClick={() => dialog.current?.close()} className="button-secondary rounded-pill px-3 py-1 text-paper">
                Close
              </button>
            </figcaption>
          </figure>
        ) : null}
      </dialog>
    </section>
  );
}
