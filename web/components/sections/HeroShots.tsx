"use client";

import Image from "next/image";
import { type KeyboardEvent, useRef, useState } from "react";
import { Lightbox } from "@/components/ui/Lightbox";
import type { HeroShot } from "@/content/features";

/** One shot of the app at a time, chosen from the thumbnails beneath it; clicking the shot opens it full size. */
export function HeroShots({ shots }: { shots: HeroShot[] }) {
  const [current, setCurrent] = useState(0);
  const [open, setOpen] = useState<number | null>(null);
  // The other shots load once the visitor reaches for them rather than with the page.
  const [warm, setWarm] = useState(false);
  const tabs = useRef<(HTMLButtonElement | null)[]>([]);
  const shot = shots[current];
  const last = shots.length - 1;

  function onKeyDown(event: KeyboardEvent) {
    const target = {
      ArrowRight: current === last ? 0 : current + 1,
      ArrowLeft: current === 0 ? last : current - 1,
      Home: 0,
      End: last,
    }[event.key];
    if (target === undefined) return;
    event.preventDefault();
    setCurrent(target);
    tabs.current[target]?.focus();
  }

  return (
    <div
      onPointerEnter={() => setWarm(true)}
      onTouchStart={() => setWarm(true)}
      onFocusCapture={() => setWarm(true)}
      className="animate-rise mx-auto mt-16 max-w-6xl [animation-delay:520ms]"
    >
      <figure role="tabpanel" id="hero-shot" aria-labelledby={`hero-tab-${current}`}>
        <button
          type="button"
          onClick={() => setOpen(current)}
          aria-label={`View full size: ${shot.alt}`}
          aria-haspopup="dialog"
          className="grid w-full cursor-zoom-in"
        >
          {shots.map((each, index) =>
            index === current || warm ? (
              <Image
                key={each.src}
                src={each.src}
                alt={index === current ? each.alt : ""}
                aria-hidden={index !== current}
                width={each.width}
                height={each.height}
                priority={index === 0}
                loading={index === 0 ? undefined : "eager"}
                sizes="(min-width: 1200px) 1152px, 96vw"
                className={`shot col-start-1 row-start-1 h-auto w-full transition-opacity duration-500 ${
                  index === current ? "opacity-100" : "opacity-0"
                }`}
              />
            ) : null,
          )}
        </button>
        <figcaption className="mt-4 text-center text-[13px] text-dim">{shot.caption}</figcaption>
      </figure>

      <div
        role="tablist"
        aria-label="Screenshots of the app"
        onKeyDown={onKeyDown}
        className="-mx-6 mt-8 flex snap-x justify-center-safe gap-3 overflow-x-auto px-6 pb-2"
      >
        {shots.map((each, index) => (
          <button
            key={each.src}
            ref={(element) => {
              tabs.current[index] = element;
            }}
            type="button"
            role="tab"
            id={`hero-tab-${index}`}
            aria-selected={index === current}
            aria-controls="hero-shot"
            tabIndex={index === current ? 0 : -1}
            onClick={() => setCurrent(index)}
            className="group flex w-28 shrink-0 snap-start flex-col items-center gap-2 sm:w-36"
          >
            {/* Eager like the hero image: they share a URL, and Next's LCP warning reads the one rendered last. */}
            <Image
              src={each.src}
              alt=""
              width={each.width}
              height={each.height}
              sizes="144px"
              loading="eager"
              className={`h-auto w-full rounded-md border transition-opacity duration-200 ${
                index === current ? "border-paper/50 opacity-100" : "border-hairline opacity-55 group-hover:opacity-90"
              }`}
            />
            <span
              className={`text-[12.5px] font-medium transition-colors ${
                index === current ? "text-paper" : "text-dim group-hover:text-mute"
              }`}
            >
              {each.label}
            </span>
          </button>
        ))}
      </div>

      <Lightbox
        shots={shots}
        index={open}
        onIndex={(index) => {
          setOpen(index);
          setCurrent(index);
        }}
        onClose={() => setOpen(null)}
      />
    </div>
  );
}
