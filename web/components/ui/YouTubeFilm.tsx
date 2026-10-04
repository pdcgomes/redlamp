"use client";

import Image from "next/image";
import { type MouseEvent, useState } from "react";
import { PlayGlyph } from "@/components/ui/Buttons";

type Props = { id: string; title: string; duration: string; poster: string; url: string };

/**
 * A YouTube video that loads only once it's played. Until then it's the film's own poster, linked
 * to the video on YouTube, so the page asks YouTube for nothing and sets no cookies. Fills its
 * parent, which sets the size.
 */
export function YouTubeFilm({ id, title, duration, poster, url }: Props) {
  const [playing, setPlaying] = useState(false);

  function play(event: MouseEvent<HTMLAnchorElement>) {
    // ⌘-click and the like still open the video on YouTube.
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
    event.preventDefault();
    setPlaying(true);
  }

  if (playing) {
    return (
      <iframe
        src={`https://www.youtube-nocookie.com/embed/${id}?autoplay=1&rel=0&playsinline=1`}
        title={title}
        allow="autoplay; encrypted-media; fullscreen; picture-in-picture; web-share"
        allowFullScreen
        referrerPolicy="strict-origin-when-cross-origin"
        className="absolute inset-0 size-full"
      />
    );
  }
  return (
    <a href={url} onClick={play} aria-label={`Play ${title} (${duration})`} className="group absolute inset-0 block">
      <Image
        src={poster}
        alt=""
        fill
        sizes="(min-width: 1100px) 1024px, 94vw"
        className="object-cover transition-[filter] duration-300 group-hover:brightness-110"
      />
      <span
        aria-hidden
        className="glass absolute top-1/2 left-1/2 grid size-[4.5rem] -translate-x-1/2 -translate-y-1/2 place-items-center rounded-full text-paper transition-transform duration-300 group-hover:scale-105"
      >
        <PlayGlyph className="ml-1 size-6" />
      </span>
      <span
        aria-hidden
        className="absolute right-4 bottom-4 rounded-md bg-wall/75 px-2 py-0.5 text-[12px] font-medium text-ring tabular-nums"
      >
        {duration}
      </span>
    </a>
  );
}
