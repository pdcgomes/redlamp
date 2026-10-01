"use client";

import Image from "next/image";
import { useState } from "react";
import { type Film, type FilmFamily, families, filmIcon, filmSample, films } from "@/content/films";

function effects(film: Film) {
  return `${film.grain} / ${film.halation}${film.bloom ? `, bloom ${film.bloom}` : ""}`;
}

export function FilmTable() {
  const [family, setFamily] = useState<FilmFamily | "all">("all");
  const [selectedId, setSelectedId] = useState(films[0].id);
  const visible = films.filter((film) => family === "all" || film.family === family);
  const selected = films.find((film) => film.id === selectedId) ?? films[0];

  return (
    <div className="flex flex-col gap-6">
      <div role="tablist" aria-label="Filter by film type" className="flex flex-wrap gap-2">
        {families.map((option) => {
          const active = option.id === family;
          return (
            <button
              key={option.id}
              role="tab"
              aria-selected={active}
              onClick={() => setFamily(option.id)}
              className={`rounded-pill px-3.5 py-1.5 text-[13px] font-medium transition-colors ${
                active ? "bg-paper text-ink" : "button-secondary text-mute hover:text-paper"
              }`}
            >
              {option.label}
            </button>
          );
        })}
      </div>

      <div className="grid gap-6 lg:grid-cols-[1.35fr_1fr]">
        <div className="surface overflow-hidden">
          <table className="w-full border-collapse text-left text-[14px]">
            <thead className="hidden text-[11px] tracking-[0.12em] text-dim uppercase md:table-header-group">
              <tr className="border-b border-hairline">
                <th className="py-3 pr-2 pl-5 font-semibold" colSpan={2}>
                  Look
                </th>
                <th className="px-2 py-3 font-semibold">Film</th>
                <th className="px-2 py-3 font-semibold">Rendered as</th>
                <th className="py-3 pr-5 pl-2 text-right font-semibold">Grain / halation</th>
              </tr>
            </thead>
            <tbody>
              {visible.map((film) => {
                const active = film.id === selected.id;
                return (
                  <tr
                    key={film.id}
                    onClick={() => setSelectedId(film.id)}
                    className={`cursor-pointer border-b border-hairline transition-colors last:border-b-0 ${
                      active ? "bg-paper/[0.07]" : "hover:bg-paper/[0.035]"
                    }`}
                  >
                    <td className="w-12 py-3 pl-5">
                      <Image src={filmIcon(film.id)} alt="" width={36} height={36} className="size-9" />
                    </td>
                    <td className="py-3 pr-2 pl-3">
                      <button
                        onClick={() => setSelectedId(film.id)}
                        aria-pressed={active}
                        className="text-left font-semibold text-paper"
                      >
                        {film.name}
                      </button>
                      <p className="mt-0.5 text-[12.5px] text-mute md:hidden">
                        {film.kind}
                        {film.iso ? `, ISO ${film.iso}` : ""}
                      </p>
                    </td>
                    <td className="hidden px-2 py-3 text-mute md:table-cell">
                      {film.maker} {film.kind.toLowerCase()}
                      {film.iso ? `, ISO ${film.iso}` : ""}
                    </td>
                    <td className="hidden px-2 py-3 text-mute md:table-cell">{film.rendered}</td>
                    <td className="hidden py-3 pr-5 pl-2 text-right font-mono text-[12.5px] text-mute md:table-cell">
                      {effects(film)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        <aside aria-live="polite" className="surface flex flex-col gap-4 p-5 lg:sticky lg:top-28 lg:self-start">
          <div className="flex items-center gap-3">
            <Image src={filmIcon(selected.id)} alt="" width={48} height={48} className="size-12" />
            <div>
              <h3 className="font-display text-[20px] leading-tight">{selected.name}</h3>
              <p className="text-[13px] text-mute">{selected.stock}</p>
            </div>
          </div>
          <p className="text-[15px] leading-relaxed text-paper/90">{selected.description}</p>
          <figure>
            <Image
              key={selected.id}
              src={filmSample(selected.id)}
              alt={`${selected.name}: three photos with Redlamp's default rendering above and the film look below`}
              width={1272}
              height={566}
              sizes="(min-width: 1024px) 440px, 94vw"
              className="h-auto w-full rounded-lg"
            />
            <figcaption className="mt-2 text-[12.5px] text-dim">
              Top: Redlamp&apos;s default rendering. Bottom: {selected.name}, with its grain, halation and bloom.
            </figcaption>
          </figure>
          <dl className="grid grid-cols-2 gap-3 border-t border-hairline pt-4 text-[13px]">
            <div>
              <dt className="text-dim">Rendered as</dt>
              <dd className="mt-0.5 text-paper/90">{selected.rendered}</dd>
            </div>
            <div>
              <dt className="text-dim">Grain / halation</dt>
              <dd className="mt-0.5 font-mono text-paper/90">{effects(selected)}</dd>
            </div>
          </dl>
        </aside>
      </div>
    </div>
  );
}
