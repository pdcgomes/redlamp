"use client";

import { useEffect, useRef, useState } from "react";

export type SiteLink = { href: string; label: string };

/** The top bar's links on phones, where they don't fit: a menu button and a panel below the bar. */
export function MobileMenu({ links }: { links: SiteLink[] }) {
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false);
        button.current?.focus();
      }
    };
    const onPointer = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!panel.current?.contains(target) && !button.current?.contains(target)) setOpen(false);
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onPointer);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onPointer);
    };
  }, [open]);

  return (
    <div className="sm:hidden">
      <button
        ref={button}
        type="button"
        aria-expanded={open}
        aria-controls="site-menu"
        aria-label={open ? "Close menu" : "Open menu"}
        onClick={() => setOpen(!open)}
        className="button-secondary ml-1 inline-flex size-[34px] items-center justify-center rounded-pill"
      >
        <svg viewBox="0 0 16 16" aria-hidden className="size-4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
          {open ? <path d="M4 4l8 8M12 4l-8 8" /> : <path d="M2.5 4.5h11M2.5 8h11M2.5 11.5h11" />}
        </svg>
      </button>
      <div
        ref={panel}
        id="site-menu"
        hidden={!open}
        className="absolute inset-x-4 top-full mt-2 rounded-card border border-hairline bg-wall-raised/95 p-2 shadow-[0_20px_50px_rgb(0_0_0/0.5)] backdrop-blur-xl"
      >
        <nav aria-label="Site">
          <ul className="flex flex-col">
            {links.map((link) => (
              <li key={link.href}>
                <a
                  href={link.href}
                  onClick={() => setOpen(false)}
                  className="block rounded-xl px-4 py-3 text-[15px] text-paper transition-colors hover:bg-paper/6"
                >
                  {link.label}
                </a>
              </li>
            ))}
          </ul>
        </nav>
      </div>
    </div>
  );
}
