# The manual's page design

What the reference's look is made of, measured from its PDF, and how the Redlamp manual adapts each part of it to the brand (`docs/brand/README.md`). The style sheet is `docs/manual/style/manual.css`.

## The reference

The *Pi Durable Technical Manual* (Pi Durable 1.0.3, October 2026) is 190 US Letter pages of HTML typeset by Paged.js in Chrome. Its look comes from these, and the manual keeps each one:

| Element | The reference | The manual |
| --- | --- | --- |
| Page | US Letter on warm paper, #FAF7F2, 20 mm sides | A4 on the brand's paper, #F3EEE8: 20 mm sides and top, 22 mm bottom |
| Body text | 9.3 pt sans, about 1.6 line height, ink #161D27 | Inter 9.2 pt, 1.6, ink #1A1414 |
| Lead paragraph | 10 pt | 10 pt |
| Section number | 8 pt monospace in the part's colour, letter-spaced | JetBrains Mono 7.6 pt in the part's accent |
| Section title | 21 pt | Inter Display Medium 21 pt, tracked −2.2% |
| Standfirst under the title | 10.4 pt serif italic, grey | Inter Display Light Italic 11.2 pt, ink-2. The brand names no serif; whether to add one is open in the canvas |
| Headings | 12.4 pt | Inter Display Medium 12.6 pt; third level Inter SemiBold 9.4 pt |
| Inline code | 8.3 pt monospace in blue | JetBrains Mono at 0.86 em, in the part's accent ink |
| Callout | tinted box, a 2 pt rule at the left, a letter-spaced monospace label | the same, tinted with the part's accent |
| Table | 6.5 pt letter-spaced monospace headers, 7.4 pt cells, hairline rows | 6 pt headers and 7.8 pt cells, the same rules |
| Figure | framed, a 2.5 pt rule at the left in the part's colour, a strip reading FIG. 1.2 and its title in monospace with a tag at the right; the caption under the frame, its first sentence bold | the same |
| Running head | the section's title at the left, the book at the right, 7.2 pt | the section's title at the left, the part at the right, 7 pt |
| Footer | the book's name in letter-spaced monospace at the left, the page number at the right | REDLAMP / USER MANUAL, and the page number |
| Front matter | roman page numbers | the same |
| Part opener | full-bleed navy; PART N; a 34 pt title; an italic summary; a rule with a short segment in the part's colour; the part's sections with their pages; an outsized numeral at the bottom right | full-bleed wall, #0A0707, lit by the website's lamp glow; the numeral in bakelite-hi, #262019 |
| Contents | each part with a coloured chip and its number; numbered sections, dotted leaders, pages in monospace | the same; sections not written yet in grey, without a page |
| Cover | a graph-paper grid; Plate I, a large technical drawing with a numbered key; a row of four small figures; a large title, an italic subtitle, a summary, and coloured dots naming the parts | the same, with a screenshot of the app as the plate, and the logo files for the title |
| Sources | a Sources line closing each section, in grey monospace | the same |
| Page references | (p. 141) after a link, small and grey | the same |

## Colours

- Text: ink #1A1414, ink-2 #5B5250, ink-3 #8C827D. Rules #DAD1C9 and #BFB4AC. Figures sit on #EBE4DC, and the frames inside diagrams on #F9F6F2.
- Part openers: wall #0A0707, titles in paper, the summary in mute #A89D98, hairlines in paper at 9% and 16%, and the glow of the website's `.lamp-glow` (`web/app/globals.css`).
- A part's accent is `oklch(47% C h)`, where h is the hue of one of the Color Mixer's bands (`ColorBand.hueDegrees`: orange 55, yellow 100, green 140, aqua 195, blue 255, purple 300, magenta 340) and C is about 0.09; its tints are at 93.5%, 86% and 74% lightness. Red, at 25, is left out, since in the brand red is only ever light. The Reference part is steel, almost neutral.
- `@page` rules can't read the style sheet's custom properties, so the margin boxes' colours are written out.

## What Chrome does, and what the build adds

Chrome draws `@page` margin boxes (`@top-left`, `@bottom-right` and so on), named pages (`page:`), page backgrounds and `counter(page, lower-roman)`. Each section has a named page, which gives its pages the section's title as their running head. What Paged.js adds and Chrome lacks is `target-counter()`, for page numbers in the contents and in cross-references; the build gets those by printing more than once. Chrome embeds a variable font as Type 3 glyphs, so the manual uses static faces.
