# Film reference photographs

Photographs shot on the film stocks Redlamp's film looks model, for checking the looks' colour and tone
against real film. `manifest.json` lists them (one entry per image); the images themselves are in
`build/film-references/<stock-id>/`, where `<stock-id>` matches a file in `research/film-data/`.

## Licence policy

- Wikimedia Commons only, and only files licensed CC0, public domain, CC BY or CC BY-SA. Each entry
  records the author, licence, licence URL and the Commons file page.
- The images are references only: never shipped, never committed, never bundled into tests or recipes.
  They stay in `build/` (gitignored), the same policy as the camera-review files under
  [DEC-17](../../docs/research/research-tracker.md#1-decisions-and-legal-questions). If one is ever shown
  outside the team, credit it as its licence requires.

## How files are chosen

- The page has to state the stock: a category named after it ("Taken on Ilford HP5 plus 400") or its
  title or description ("Shot on Portra 400"). Family categories ("Taken on Fuji Velvia") only count
  when the page names the speed. Photographer folders with ambiguous names ("Kodak400") are not used.
- Skipped: pages naming a second film (any modelled stock, or a common other one such as C200 or
  Kentmere); cross-processing, expired film, redscale, push or pull processing, toy and pinhole
  cameras, light leaks, multiple exposures, colour filters, long exposures, underwater shots,
  digital edits, film emulations, crops and restorations (in the languages Commons pages most often
  use); colour stocks converted to black and white; photos of the film, its box or cartridge; and
  dates before the current emulsion existed (Portra 400 before 2010, E100 before 2018, and so on).
- Up to 20 files per stock (12 for the optional Vision3 stocks), at most four per photographer until
  the stock has eight, spread across scene types. Each is a Commons thumbnail at a standard width
  (960 or 1280 px), so the long edge is about 1200-1600 px; originals smaller than that (down to
  1000 px) come at full size.
- `EXCLUDE` in `fetch.py` lists files dropped after looking at them, with the reason.

Each manifest entry has `stock`, `file`, `source` (file page), `imageURL`, `author`, `licence`,
`licenceURL`, `description`, `width`, `height` and `sha256`, plus `title`, `date` (as Commons gives
it), `evidence` (where the page states the stock) and `scene` (a rough guess from the page's words).

## Fetching

```sh
python3 research/film-references/fetch.py                      # download what the manifest lists but is missing
python3 research/film-references/fetch.py discover             # re-query Commons and top each stock up
python3 research/film-references/fetch.py discover --stock fuji-velvia-50 --refresh --dry-run
```

Both steps are idempotent and resumable: files already on disk are skipped, and the manifest is
written after every download. Requests go out one a second with a descriptive User-Agent; the first
403 or 429 stops the run (rerun later to resume). `discover` caches the Commons answers in
`build/film-references/.cache/`; `--refresh` re-queries them. It keeps the files already in the
manifest and only adds new ones, unless the rules or `EXCLUDE` now reject them.
