"use client";

import Image from "next/image";
import {
  createContext,
  type KeyboardEvent,
  type PointerEvent,
  type ReactNode,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import type { Shot } from "@/content/features";

type Props = {
  shots: Shot[];
  /** The shot on show, or `null` while closed. */
  index: number | null;
  onIndex: (index: number) => void;
  onClose: () => void;
};

function Chevron({ direction }: { direction: "left" | "right" }) {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
      <path d={direction === "left" ? "M10 3.5L5.5 8l4.5 4.5" : "M6 3.5L10.5 8 6 12.5"} />
    </svg>
  );
}

function Cross() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-3.5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
      <path d="M4 4l8 8M12 4l-8 8" />
    </svg>
  );
}

const sizes = "(min-width: 768px) calc(100vw - 10rem), 100vw";

/**
 * Screenshots at full size, one at a time. ← → (or a swipe, the arrows, a thumbnail) move through
 * them; Esc, the close button or a click beside the image closes it.
 */
export function Lightbox({ shots, index, onIndex, onClose }: Props) {
  const dialog = useRef<HTMLDialogElement>(null);
  const close = useRef<HTMLButtonElement>(null);
  const press = useRef<{ x: number; y: number } | null>(null);
  const dragged = useRef(false);
  const count = shots.length;
  const open = index !== null;
  const shot = index === null ? null : shots[index];
  const step = (by: number) => {
    if (index !== null) onIndex((index + by + count) % count);
  };

  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (open && !element.open) {
      element.showModal();
      close.current?.focus();
    }
    if (!open && element.open) element.close();
  }, [open]);

  // The page behind keeps its place instead of scrolling under the lightbox.
  useEffect(() => {
    if (!open) return;
    const root = document.documentElement;
    const overflow = root.style.overflow;
    root.style.overflow = "hidden";
    return () => {
      root.style.overflow = overflow;
    };
  }, [open]);

  function onKeyDown(event: KeyboardEvent) {
    if (count < 2 || index === null) return;
    const target = { ArrowRight: (index + 1) % count, ArrowLeft: (index - 1 + count) % count, Home: 0, End: count - 1 }[
      event.key
    ];
    if (target === undefined) return;
    event.preventDefault();
    onIndex(target);
  }

  function onPointerDown(event: PointerEvent) {
    press.current = { x: event.clientX, y: event.clientY };
    dragged.current = false;
  }

  function onPointerUp(event: PointerEvent) {
    const start = press.current;
    press.current = null;
    if (!start) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    dragged.current = Math.hypot(dx, dy) > 10;
    if (count > 1 && Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.5) step(dx < 0 ? 1 : -1);
  }

  const neighbours = count > 1 && index !== null ? [(index + count - 1) % count, (index + 1) % count] : [];

  return (
    <dialog
      ref={dialog}
      aria-label="Screenshots"
      onClose={onClose}
      onKeyDown={onKeyDown}
      onPointerDown={onPointerDown}
      onPointerUp={onPointerUp}
      onClick={(event) => {
        // A swipe ends in a click too; only a click that stayed put closes.
        if (dragged.current) return;
        if (event.target instanceof HTMLElement && event.target.dataset.dismiss !== undefined) dialog.current?.close();
      }}
      data-dismiss
      className="m-0 h-dvh max-h-none w-screen max-w-none touch-pan-y touch-pinch-zoom border-0 bg-transparent p-0 text-paper [--chrome:9.5rem] backdrop:bg-wall/90 backdrop:backdrop-blur-md open:flex open:flex-col md:[--chrome:13rem]"
    >
      {shot && index !== null ? (
        <>
          <div data-dismiss className="flex shrink-0 items-center justify-between gap-4 px-4 pt-4 sm:px-6">
            {count > 1 ? (
              <div className="flex items-center gap-1 text-[13px] text-mute">
                <button
                  type="button"
                  onClick={() => step(-1)}
                  aria-label="Previous screenshot"
                  className="grid size-9 place-items-center rounded-full hover:bg-paper/10 md:hidden"
                >
                  <Chevron direction="left" />
                </button>
                <span className="px-1 tabular-nums" aria-live="polite">
                  {index + 1} of {count}
                </span>
                <button
                  type="button"
                  onClick={() => step(1)}
                  aria-label="Next screenshot"
                  className="grid size-9 place-items-center rounded-full hover:bg-paper/10 md:hidden"
                >
                  <Chevron direction="right" />
                </button>
              </div>
            ) : (
              <span />
            )}
            <button
              ref={close}
              type="button"
              onClick={() => dialog.current?.close()}
              aria-label="Close"
              className="button-secondary grid size-9 place-items-center rounded-full"
            >
              <Cross />
            </button>
          </div>

          <div data-dismiss className="relative flex min-h-0 flex-1 items-center justify-center px-4 py-3 sm:px-6 md:px-20">
            <Image
              key={shot.src}
              src={shot.src}
              alt={shot.alt}
              width={shot.width}
              height={shot.height}
              sizes={sizes}
              draggable={false}
              style={{ width: `min(100%, calc((100dvh - var(--chrome)) * ${shot.width / shot.height}))` }}
              className="animate-fade-in shot h-auto select-none"
            />
            {count > 1 ? (
              <>
                <button
                  type="button"
                  onClick={() => step(-1)}
                  aria-label="Previous screenshot"
                  className="glass absolute top-1/2 left-5 hidden size-11 -translate-y-1/2 place-items-center rounded-full text-paper transition-colors hover:bg-bakelite-hi md:grid"
                >
                  <Chevron direction="left" />
                </button>
                <button
                  type="button"
                  onClick={() => step(1)}
                  aria-label="Next screenshot"
                  className="glass absolute top-1/2 right-5 hidden size-11 -translate-y-1/2 place-items-center rounded-full text-paper transition-colors hover:bg-bakelite-hi md:grid"
                >
                  <Chevron direction="right" />
                </button>
              </>
            ) : null}
          </div>

          <div data-dismiss className="flex shrink-0 flex-col items-center gap-4 px-6 pt-1 pb-5">
            <p className="max-w-3xl text-center text-[13.5px] leading-snug text-mute">{shot.caption}</p>
            {count > 1 ? (
              <div className="hidden max-w-full gap-2 overflow-x-auto p-1 md:flex">
                {shots.map((thumb, i) => (
                  <button
                    key={thumb.src}
                    type="button"
                    onClick={() => onIndex(i)}
                    aria-label={`Screenshot ${i + 1}: ${thumb.caption}`}
                    aria-current={i === index}
                    className={`relative h-12 w-[4.75rem] shrink-0 overflow-hidden rounded-md border transition-opacity ${
                      i === index ? "border-paper/60 opacity-100" : "border-hairline opacity-45 hover:opacity-80"
                    }`}
                  >
                    <Image src={thumb.src} alt="" fill sizes="80px" className="object-cover object-top" />
                  </button>
                ))}
              </div>
            ) : null}
          </div>

          {neighbours.map((i) => (
            <Image
              key={`next-${shots[i].src}`}
              src={shots[i].src}
              alt=""
              aria-hidden
              width={shots[i].width}
              height={shots[i].height}
              sizes={sizes}
              loading="eager"
              className="hidden"
            />
          ))}
        </>
      ) : null}
    </dialog>
  );
}

const OpenShot = createContext<((index: number) => void) | null>(null);

/** One lightbox for the screenshots inside it, opened by their `ShotButton`s. */
export function LightboxGroup({ shots, children }: { shots: Shot[]; children: ReactNode }) {
  const [index, setIndex] = useState<number | null>(null);
  return (
    <OpenShot.Provider value={setIndex}>
      {children}
      <Lightbox shots={shots} index={index} onIndex={setIndex} onClose={() => setIndex(null)} />
    </OpenShot.Provider>
  );
}

/** A screenshot that opens its group's lightbox at `index`. */
export function ShotButton({
  index,
  label,
  className = "",
  children,
}: {
  index: number;
  label: string;
  className?: string;
  children: ReactNode;
}) {
  const open = useContext(OpenShot);
  return (
    <button
      type="button"
      onClick={() => open?.(index)}
      aria-label={`View full size: ${label}`}
      aria-haspopup="dialog"
      className={`block w-full cursor-zoom-in text-left ${className}`}
    >
      {children}
    </button>
  );
}
