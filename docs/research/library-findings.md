# Library and catalog: findings

What Redlamp's library should take from Lightroom Classic's Library module, the tools professionals cull and ingest with, the open-source managers and digital asset managers (DAMs), and the AI culling tools, and which complaints about them recur. Researched on 5 October 2026 for LIB-01. The track's decisions (DEC-42 to DEC-51) and work (LIB-01 to LIB-35) are in section 13 of the [research tracker](research-tracker.md#13-library-and-catalog), and its architecture is the [library design](../plans/2026-10-05-library-design.md).

The evidence is in four notes:

- [Lightroom Classic and Lightroom](notes/LIB-lightroom-classic.md): Classic 15.6's catalog and Library module, and 17 complaint topics counted over about 4,000 thread titles.
- [Professional tools](notes/LIB-pro-tools.md): Capture One, Photo Mechanic (with Plus), Adobe Bridge and FastRawViewer.
- [Open-source managers and DAMs](notes/LIB-dams-and-open-source.md): darktable, digiKam, IMatch, Photo Supreme, NeoFinder, Peakto, Excire, Apple Photos, ACDSee, ON1 and DxO.
- [AI culling, renaming, platform and scale](notes/LIB-culling-renaming-platform.md): five AI culling tools, six renaming tools, the macOS 26 APIs the library would use (three measured), and library sizes on network storage.

Added on 6 October 2026: [Katami](notes/LIB-katami.md), a raw photo browser for the Mac, read against the track, with Library Health, moments and the tracker changes they'd need, for the owner to accept.

Added on 6 October 2026: [Cling](notes/LIB-cling.md), a fuzzy file finder for the Mac, read against the library's index, search and change tracking, with four of its ideas measured (names folded to bytes, a mapped column store, short text with fuzzy matching and typos, busy folders left out of change tracking) and the tracker changes they'd need, for the owner to accept.

Each note keeps its sources and what it couldn't reach or confirm; this document keeps their "(unverified)" marks. Adobe's help site, DPReview and Reddit refused automated requests, so Adobe's own wording is unchecked, and Lightroom Classic's counts are thread titles sorted by keyword patterns, a rough measure of frequency.

## 1. Summary

- **Photographers rely on** culling at the speed of a key press, finding photos again, metadata other apps can read, their own folders, and safe ingest from cards ([section 2](#2-what-photographers-rely-on)).
- **The complaints that recur are about architecture more than features.** Photos moved or renamed outside the app go missing (reported for 11 products), network volumes are slow or barred (9), the interface waits on the disk (8), a library can't be shared between computers (7), and everyday actions slow down as the library grows ([section 3](#3-recurring-complaints)).
- **Redlamp's decisions remove the causes of several.** Metadata in each photo's sidecar (DEC-42) locks nothing in a database, the index on the Mac (LIB-05) keeps databases off network volumes, and the design's budgets, met from the index and the preview store (DEC-47), keep the interface off the photos' disks.
- **Some of what Redlamp needs, no product documents:** search as you type over a million photos, and renaming that combines regular expressions, sub-second time, file pairing, a full preview and undo. Only digiKam finds moved files unaided, and of the manuals reached only FastRawViewer's describes verified copies.
- **AI culling has converged** on focus, open eyes, faces and near-duplicates, and only FilterPixel is known to run it in the cloud. It fails on small embedded previews, hidden faces, the wrong genre and analysis of whole catalogs. Apple's Vision groups a burst without ranking it; Foundation Models drafts queries but misreads dates.
- **Tracker changes** ([section 7](#7-proposed-tracker-changes)): three new rows, LIB-31 split so exact duplicates ship in 1.0, wording for eighteen rows, and three recorded skips.

## 2. What photographers rely on

Ranked by how widely the products studied build each feature, then by how much the notes show photographers depending on it: praise, requests, and the size of the threads when it breaks. It is a reading of the notes, not a survey.

| # | Feature | Models | Evidence that photographers depend on it |
| --- | --- | --- | --- |
| 1 | Rating, flagging and labelling at a key press, moving to the next photo, from the embedded preview | Photo Mechanic, Capture One's Cull view, Lightroom Classic's keys | Bridge users recall rating three to five photos a second in older versions; a Classic thread on not advancing to the next photo has 326 replies ([pro tools §4](notes/LIB-pro-tools.md#4-adobe-bridge), [Classic §10](notes/LIB-lightroom-classic.md#10-recurring-complaints-ranked)) |
| 2 | Finding photos again: filters with counts, saved searches, smart collections | Classic's filter bar and smart collections, Photo Mechanic Plus's queries, digiKam | Finding photos and collections are Classic's third and sixth complaint topics (160 and 141 titles); NeoFinder's testimonials praise its search ([Classic §3](notes/LIB-lightroom-classic.md#3-search-and-smart-collections), [DAMs §3.5](notes/LIB-dams-and-open-source.md#35-neofinder-93-macos)) |
| 3 | Ratings, labels and keywords in XMP that other apps read | Photo Mechanic, FastRawViewer; Narrative and Aftershoot hand culls to editors this way | Aftershoot advises culling before importing into Lightroom or Capture One; Classic's request for flags and collections in XMP dates from 2011 ([culling §1.2](notes/LIB-culling-renaming-platform.md#12-how-photographers-use-them), [Classic §6](notes/LIB-lightroom-classic.md#6-xmp-and-interop)) |
| 4 | Their own folders as the organisation | Bridge, Photo Mechanic, FastRawViewer; Lightroom Desktop's Local mode (2023) | Folders are Classic's fourth topic (157 titles), and moves made outside the app head section 3 ([Classic §1](notes/LIB-lightroom-classic.md#1-catalog-and-storage)) |
| 5 | Ingest from cards with a second copy, templates and no duplicates | Photo Mechanic's Ingest; Capture One's and Classic's importers | Import has more Classic titles than any other topic (234); Camera Bits' testimonials cite ingest to two places on deadline ([pro tools §3](notes/LIB-pro-tools.md#3-photo-mechanic-and-photo-mechanic-plus)) |
| 6 | Keywords and captions entered quickly and consistently | Classic's keyword list and sets; Photo Mechanic's metadata template | Press testimonials single out captioning on deadline; users praise digiKam's tagging ([DAMs §3.2](notes/LIB-dams-and-open-source.md#32-digikam-91-linux-macos-windows)) |
| 7 | Previews that keep large, slow or disconnected libraries browsable | Classic's preview tiers; NeoFinder, Photo Supreme, IMatch, Peakto | Testimonials praise NeoFinder's view of offline drives; on slow storage, a local preview of every photo is what helped ([culling §4.2](notes/LIB-culling-renaming-platform.md#42-what-was-slow-what-broke-what-helped)) |
| 8 | Collections, stacks, and raw and JPEG pairs | Classic; Capture One's albums and pairing | Classic's two stacking requests date from 2011; Capture One's has 77 votes ([Classic §2](notes/LIB-lightroom-classic.md#2-browsing-and-culling)) |
| 9 | Batch renaming by template | Photo Mechanic, Bridge, digiKam, A Better Finder Rename | Each has its own token language; bursts need sub-second time ([culling §2](notes/LIB-culling-renaming-platform.md#2-renaming-tools)) |
| 10 | Duplicates, faces and places | Classic; digiKam | A Classic question on removing duplicates has 142,828 views; face requests have 50 titles ([Classic §10](notes/LIB-lightroom-classic.md#10-recurring-complaints-ranked)) |

AI first passes are newer: some Narrative users pick only from its top two tiers, but most of the evidence is the vendors' own ([culling §1](notes/LIB-culling-renaming-platform.md#1-ai-assisted-culling)).

## 3. Recurring complaints

The notes rank complaints differently: Lightroom Classic's by thread titles, the professional tools' and the DAMs' by products, the culling note's by sources. Here a complaint ranks by the number of products, across all four notes, it was reported for; ties go to the complaint more notes report, then to the larger Lightroom Classic count. Slowness is split by cause, since each cause needs a different answer.

| # | Complaint | Products (notes) | Evidence |
| --- | --- | --- | --- |
| 1 | Photos moved or renamed outside the app go missing, reappear as duplicates or lose their records; relinking is by hand | 11: Lightroom Classic, Capture One, Photo Mechanic Plus, Bridge, darktable, DxO, ON1, Apple Photos, IMatch, Photo Supreme, NeoFinder (3) | [Classic §1](notes/LIB-lightroom-classic.md#1-catalog-and-storage), [DAMs §4](notes/LIB-dams-and-open-source.md#4-recurring-complaints-ranked); [LrC BR7][lrc-br7] (137 replies), [C1 2024][pt-c1-renames], [DxO 2025][dam-dx3], [Apple Photos][dam-ap1] |
| 2 | Network volumes are slow or unsupported, and the database can't live on them | 9: Lightroom Classic, Photo Mechanic, Capture One, Bridge, darktable, digiKam, Apple Photos, IMatch, DxO (4) | [pro tools §6](notes/LIB-pro-tools.md#6-recurring-complaints-ranked), [culling §4.2](notes/LIB-culling-renaming-platform.md#42-what-was-slow-what-broke-what-helped); [LrC FR1][lrc-fr1] (570 replies), [PM 2022][pt-pm-nas], [darktable 2024][cul-dt7], [digiKam 2025][dam-dk17] |
| 3 | The interface waits on the disk: views, sorts and filters read every file, and start-up checks and rescans block work | 8: Photo Mechanic, Capture One, Bridge, darktable, digiKam, DxO, ON1, IMatch (3) | [DAMs §4](notes/LIB-dams-and-open-source.md#4-recurring-complaints-ranked), [culling §5](notes/LIB-culling-renaming-platform.md#5-recurring-complaints-ranked-by-how-often-we-saw-them); [PM 2020][pt-pm-sort], [PM 2025][cul-cb3], [darktable 2026][dam-dt14] (58 s per cold start on NFS), [DxO 2025][dam-dx5] |
| 4 | A library can't be shared between computers or by a team | 7: Lightroom Classic, Capture One, Photo Mechanic Plus, darktable, digiKam, Excire, IMatch (4) | [DAMs §4](notes/LIB-dams-and-open-source.md#4-recurring-complaints-ranked), [culling §5](notes/LIB-culling-renaming-platform.md#5-recurring-complaints-ranked-by-how-often-we-saw-them); [LrC FR1][lrc-fr1], [LrC F14][lrc-f14], [PM 2023][cul-cb8], [digiKam 2025][dam-dk20] |
| 5 | Everyday actions slow down as the library grows | 6: Lightroom Classic, Capture One, darktable, digiKam, IMatch, Photo Supreme (4) | [Classic §8](notes/LIB-lightroom-classic.md#8-scale-and-performance), [DAMs §4](notes/LIB-dams-and-open-source.md#4-recurring-complaints-ranked); [LrC QA1][lrc-qa1] (633,347 views), [C1 2023][pt-c1-dam], [IMatch 2026][dam-im12], [Photo Supreme 2026][dam-ps1] |
| 6 | Indexing and background analysis take hours or days, and slow or crash the app | 6: Lightroom Classic, Capture One, Photo Mechanic Plus, digiKam, ON1, Narrative (4) | [Classic §9](notes/LIB-lightroom-classic.md#9-ai-features), [culling §5](notes/LIB-culling-renaming-platform.md#5-recurring-complaints-ranked-by-how-often-we-saw-them); [C1 2023][pt-c1-metadata], [PM 2019][cul-cb4], [digiKam 2024][dam-dk18], [ON1][dam-or2] |
| 7 | Previews fill the disk, go stale, lag or don't show the edit | 6: Lightroom Classic, Bridge, Capture One, Photo Mechanic Plus, FastRawViewer, DxO (3) | [Classic §10](notes/LIB-lightroom-classic.md#10-recurring-complaints-ranked), [pro tools §6](notes/LIB-pro-tools.md#6-recurring-complaints-ranked); [LrC F4][lrc-f4] (315 GB of previews), [LrC BR18][lrc-br18], [C1 2023][pt-c1-cull-edits], [FRV 2024][pt-frv-grid] |
| 8 | Labels, flags and keywords don't survive the trip between apps, and sidecars and databases disagree | 6: Lightroom Classic, Capture One, FastRawViewer, Bridge, darktable, DxO (3) | [pro tools §6](notes/LIB-pro-tools.md#6-recurring-complaints-ranked), [DAMs §4](notes/LIB-dams-and-open-source.md#4-recurring-complaints-ranked); [LrC FR3][lrc-fr3], [C1 2023][pt-c1-labels], [FRV 2025][pt-frv-pick], [darktable 2025][dam-dt18] |
| 9 | Import is slow, fails, or lacks raw-only and card-erasing options | 5: Lightroom Classic, Capture One, Photo Mechanic, Bridge, darktable (4) | [Classic §10](notes/LIB-lightroom-classic.md#10-recurring-complaints-ranked), [pro tools §3](notes/LIB-pro-tools.md#3-photo-mechanic-and-photo-mechanic-plus); [LrC FR18][lrc-fr18], [LrC FR19][lrc-fr19], [C1 2024][pt-c1-dupes], [darktable 2021][dam-dt22] |
| 10 | Finding photos falls short: filters that can't combine, sorts on one field, search that is partial or slow | 5: Lightroom Classic, Bridge, Capture One, IMatch, Photo Supreme (3) | [Classic §3](notes/LIB-lightroom-classic.md#3-search-and-smart-collections), [pro tools §4](notes/LIB-pro-tools.md#4-adobe-bridge); [LrC FR12][lrc-fr12], [Bridge 2019][pt-br-and], [C1 catalogs][pt-c1-catalogs], [IMatch help][dam-im3] |
| 11 | Vendors' changes strand libraries: withdrawn products, one-way upgrades, dropped platforms and databases | 5: Photo Mechanic, Capture One, Bridge, Lightroom Classic, digiKam (3) | [pro tools §6](notes/LIB-pro-tools.md#6-recurring-complaints-ranked), [Classic §1](notes/LIB-lightroom-classic.md#1-catalog-and-storage), [DAMs §3.2](notes/LIB-dams-and-open-source.md#32-digikam-91-linux-macos-windows); [Camera Bits 2026][pt-pm-withdrawn], [C1 16.8][pt-c1-168], [Bridge 2026][pt-br-unusable], [LrC BR9][lrc-br9] |
| 12 | Keyword lists are hard to maintain and lose options on export | 4: Lightroom Classic, Capture One, FastRawViewer, digiKam (3) | [Classic §4](notes/LIB-lightroom-classic.md#4-keywords-and-metadata); [LrC FR13][lrc-fr13], [LrC F8][lrc-f8], [C1 switching FAQ][pt-c1-switching], [FRV 2026][pt-frv-keywords] |
| 13 | Work is lost to actions that can't be undone: culling, renames, moves, and removals that take more than asked | 4: Photo Mechanic, Capture One, Bridge, Lightroom Classic (3) | [pro tools §6](notes/LIB-pro-tools.md#6-recurring-complaints-ranked), [culling §2.2](notes/LIB-culling-renaming-platform.md#22-preview-collisions-and-undo); [PM 2025][pt-pm-undo], [C1 2023][pt-c1-undo], [Bridge 2019][pt-br-rename-undo], [LrC BR17][lrc-br17] |
| 14 | Culling keys are missing, can't be remapped, or break | 4: Lightroom Classic, Capture One, Bridge, FastRawViewer (2) | [Classic §7](notes/LIB-lightroom-classic.md#7-module-switching-and-keys), [pro tools §6](notes/LIB-pro-tools.md#6-recurring-complaints-ranked); [LrC FR4][lrc-fr4] (277 replies), [LrC BR22][lrc-br22] (326 replies), [C1 2023][pt-c1-reject], [Bridge 2023][pt-br-purple] |
| 15 | Catalogs corrupt or fail to open | 3: Lightroom Classic, Photo Mechanic Plus, Capture One (3) | [Classic §1](notes/LIB-lightroom-classic.md#1-catalog-and-storage); [LrC BR8][lrc-br8], [LrC F12][lrc-f12], [PM 2024][cul-cb7], [C1 database error][pt-c1-dberror] |
| 16 | Duplicates are hard to find, slow to find and risky to delete | 3: Lightroom Classic, digiKam, Capture One (3) | [Classic §9](notes/LIB-lightroom-classic.md#9-ai-features), [DAMs §3.2](notes/LIB-dams-and-open-source.md#32-digikam-91-linux-macos-windows); [LrC QA2][lrc-qa2] (142,828 views), [LrC BR17][lrc-br17], [digiKam 2024][dam-dk18] |
| 17 | AI culling misjudges outside portraits, on small previews or with hidden faces | 3: Lightroom Classic, Narrative, Aftershoot (2) | [Classic §9](notes/LIB-lightroom-classic.md#9-ai-features), [culling §1.2](notes/LIB-culling-renaming-platform.md#12-how-photographers-use-them); [LrC AD2][lrc-ad2], [Narrative focus][cul-n7], [Narrative faces][cul-n12], [Aftershoot genres][cul-as5] |
| 18 | Stacks are tied to one folder, and auto-stacking splits brackets | 2: Lightroom Classic, Capture One (2) | [Classic §2](notes/LIB-lightroom-classic.md#2-browsing-and-culling); [LrC FR6][lrc-fr6], [LrC FR7][lrc-fr7], [C1 2023][pt-c1-stacking] |

Complaints reported for Lightroom Classic alone rank after these, however large their count there: sync with the cloud apps (its second topic, 180 titles), face recognition (74), the Map module (58), folder panel limits, and sub-second time in file names. Counted by readers instead, its most-viewed threads are about speed, and the request with the most replies asks for catalogs on network drives.

## 4. How the products compare

### 4.1 Storage model and lock-in

| Product | The record | What stays behind |
| --- | --- | --- |
| Lightroom Classic | One SQLite catalog; XMP as a partial copy | Collections, stacks, virtual copies and history; the format changed in 14.0, 15.0 and 15.4 |
| Capture One | Sessions (folders with a small database) or catalogs; XMP for ratings, tags and keywords | Edits, in its own `.cos` files or the catalog; documents upgrade one way |
| Photo Mechanic | No database, XMP written at once; Plus added catalogs | Plus, withdrawn in February 2026 |
| Bridge, FastRawViewer | Folders with XMP | Bridge's collections, by fixed path |
| darktable, digiKam, IMatch, Photo Supreme, DxO | A database, with XMP copies | darktable's database overrides newer XMP; DxO keys photos by path |
| Apple Photos | A library package, no sidecars | All but what's exported |

Apart from the folder browsers, most keep a database as the record and treat sidecars as copies; ON1, with edits in `.on1` sidecars, and NeoFinder, writing XMP into files, are the exceptions. Lightroom Desktop's Local mode (2023), folders with edits in XMP and no catalog, is Adobe offering the model DEC-42 chose ([Classic §1](notes/LIB-lightroom-classic.md#1-catalog-and-storage), [DAMs §2](notes/LIB-dams-and-open-source.md#2-at-a-glance)).

### 4.2 Culling speed

Speed comes from not rendering. Photo Mechanic reads a raw's metadata (usually under 64 KB) and its embedded JPEG, never most of the file, and held arrow keys move at the key-repeat rate; Capture One's Cull view also shows embedded previews, so the screen shows the camera's JPEG, not the edit. Then the disk sets the pace: of the professional tools, only FastRawViewer tunes reads per volume (1 to 3 at once on hard disks, 2 to 3 on gigabit NAS, 4 to 6 on fast cards) and prefetches in the direction of travel. Lightroom Classic has the single keys switchers know but no shortcut editor; Capture One, Photo Mechanic, Bridge and FastRawViewer reassign keys, and FastRawViewer ships keymaps imitating Lightroom, Bridge and Photo Mechanic ([pro tools §1](notes/LIB-pro-tools.md#1-summary), [Classic §7](notes/LIB-lightroom-classic.md#7-module-switching-and-keys)).

### 4.3 Search and smart collections

Every app has rule-based search, split across tools. Lightroom Classic's smart collections nest groups of rules but don't sync or show stacks, and their live counts slow metadata entry in large catalogs; content search is only in the cloud apps. Photo Mechanic Plus's queries take named fields, AND, OR and NOT, empty fields, relative dates and distance from a point; darktable adds EXCEPT and ranges. IMatch's search takes about 1 s per 100,000 files and Photo Supreme's 2 to 7 s at 700,000, and no product documents search as you type over a million ([Classic §3](notes/LIB-lightroom-classic.md#3-search-and-smart-collections), [DAMs §3](notes/LIB-dams-and-open-source.md#3-products)); the design measured SQLite alone at about 60 ms to count two predicates over a million photos ([design](../plans/2026-10-05-library-design.md#the-index-at-a-million-photos-lib-05)).

### 4.4 Keywords

Lightroom Classic's keyword list is the reference: nesting, export and person options on each keyword, sets of nine on ⌥1 to ⌥9, and flat and hierarchical forms in XMP. Its weak points are upkeep and exchange: duplicates are merged by hand, the text export keeps one option, and imports break on a comma. darktable adds category and private flags; Capture One receives Lightroom catalogs with their keywords flattened; Photo Mechanic's metadata template applies only the fields ticked and expands code replacements, which press photographers cite for working to deadlines ([Classic §4](notes/LIB-lightroom-classic.md#4-keywords-and-metadata), [pro tools §3](notes/LIB-pro-tools.md#3-photo-mechanic-and-photo-mechanic-plus)).

### 4.5 Renaming and import

Photo Mechanic's Ingest is the model: several cards at once to two destinations, folders named from variables, photos already ingested skipped, an optional start when a card goes in, and the card unmounted or erased. Capture One's importer backs up, excludes duplicates and erases; Lightroom Classic has matched duplicates on capture time and size since 14.4. Of the manuals reached, only FastRawViewer's describes verified copies (unverified for Capture One and Photo Mechanic). For renaming, A Better Finder Rename has regular expressions, sub-second ordering, counters kept across sessions, file pairing and a preview that highlights changes; digiKam has unique suffixes and sequences per folder; Bridge keeps the old name in XMP; Lightroom Classic's templates had no sub-second time as of 15.0. None combines them, or documents undoing a finished batch ([culling §2](notes/LIB-culling-renaming-platform.md#2-renaming-tools)).

### 4.6 Interop

XMP carries ratings and keywords well and labels poorly. Lightroom Classic writes develop settings, ratings, label text and keywords, flags since 13.2 (which Bridge ignores) and the label's colour since 15.0, but never collections, stacks or virtual copies. Capture One maps its tags to IPTC Urgency (switchable since 16.5.6) and knows English label names only, Lightroom's pick flag isn't in the XMP specification, and FastRawViewer writes Bridge's, Lightroom's or custom label names and can write rejects as rating −1. XMP embedded in DNG, JPEG or TIFF makes backups copy the whole file after every change. In our test, Apple's ImageIO kept every value through an XMP round trip but rewrote the layout ([Classic §6](notes/LIB-lightroom-classic.md#6-xmp-and-interop), [pro tools §2](notes/LIB-pro-tools.md#2-capture-one), [culling §3.1](notes/LIB-culling-renaming-platform.md#31-measurements)).

### 4.7 Scale and network volumes

| Product | Libraries reported | Behaviour |
| --- | --- | --- |
| Lightroom Classic | Over 996,000; about 2,000,000 | Opens in under 10 s; works, depending on hardware |
| Lightroom Classic | 338,000 to 540,000 | A choppy grid; with sync on, a rating or collection add takes 20 to 30 minutes |
| Photo Mechanic Plus | A 1,000,000 test; users up to 1,600,000 | No limit, says Camera Bits; ten hours for the first 100,000 of one library of over a million |
| digiKam, IMatch | Over 1,000,000 | digiKam on SQLite in WAL mode; IMatch advises 32 GB and a fast SSD |
| Photo Supreme | 700,000 (vendor test) | Searches of 2 to 7 s; the view capped at 250,000 |
| darktable | Over 389,000 | At 183,000 (3.4), a 128-photo import took 113 s instead of 4 |
| Capture One | Tens of thousands | May slow down, says Capture One; one user's 12-second freezes at 28,000 |

Every vendor whose advice the notes found keeps the database on a local disk. On slow storage, tools stayed usable when they showed local previews and froze when the interface touched the volume; darktable 5.8 cut a cold start on NFS from 58 s to about 3 s by listing each folder once, in parallel and in the background. Whether FSEvents on a network volume reports other computers' changes is undocumented (unverified), so the notes advise polling ([culling §4](notes/LIB-culling-renaming-platform.md#4-library-sizes-and-network-storage), [DAMs §1](notes/LIB-dams-and-open-source.md#1-summary)).

### 4.8 AI

The culling tools judge focus, open eyes, faces and near-duplicates and differ in presentation: Narrative's five tiers per scene with reasons, Aftershoot's score from 1 to 100 with buckets and a target share, FilterPixel's scores by genre, and Lightroom Classic's thresholds per criterion. Narrative, Aftershoot and Excire run on the computer and FilterPixel's DeepCull in its cloud; Adobe doesn't say where Assisted Culling runs (unverified). Small embedded previews inflate Narrative's focus scores, faces are missed, the wrong genre misleads, and Lightroom's analysis of a whole catalog crashed for one user. digiKam 9.2.0 turns a request in words into an Advanced Search on the computer. On our M1 Ultra, Vision took 10 to 30 ms per request on an extracted preview (about 40 hours for a million photos on one serial queue, extraction included) and grouped a still-life series without ordering it; Foundation Models' queries were well formed but misread dates and invented or dropped fields ([culling §1](notes/LIB-culling-renaming-platform.md#1-ai-assisted-culling), [§3](notes/LIB-culling-renaming-platform.md#3-apple-platform-capabilities-on-macos-26)).

## 5. Recommendations

**Adopt** takes the idea, **Do better** delivers the capability by Redlamp's own design, **Build** has no usable prior art, and **Skip** is a decision not to. Row is the tracker row a recommendation belongs to, or "new" (section 7).

| # | Recommendation | Verdict | Row | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Collections, stacks and virtual copies saved in the sidecar, as rating, flag, label and history are, so the index can always be rebuilt | Do better | LIB-23, LIB-28, EDT-09 | [Classic §6](notes/LIB-lightroom-classic.md#6-xmp-and-interop), [§11](notes/LIB-lightroom-classic.md#11-recommendations-for-redlamp) |
| 2 | The index on the Mac's own disk in macOS's SQLite, rebuildable from the photos and sidecars | Adopt | LIB-05 | [culling §4.2](notes/LIB-culling-renaming-platform.md#42-what-was-slow-what-broke-what-helped), [pro tools §7](notes/LIB-pro-tools.md#7-recommendations-for-redlamp) |
| 3 | Moved photos found by a sidecar ID, then file identity, then size and a partial hash; restored volumes re-matched by folders and IDs; FSEvents replayed per volume, network volumes polled; rescans that propose and never drop a record | Do better | LIB-08 | [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp), [culling §3](notes/LIB-culling-renaming-platform.md#3-apple-platform-capabilities-on-macos-26), [Classic §1](notes/LIB-lightroom-classic.md#1-catalog-and-storage) |
| 4 | Missing and offline as filters and smart-collection rules | Do better | LIB-18 | [Classic §3](notes/LIB-lightroom-classic.md#3-search-and-smart-collections) |
| 5 | A sidecar checked unchanged before it's written and merged field by field if another app or Mac changed it; nothing written beside photos because a folder was viewed | Do better | LIB-11 | [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp), [pro tools §7](notes/LIB-pro-tools.md#7-recommendations-for-redlamp) |
| 6 | Several Macs sharing folders through sidecars, each Mac's index taking in the others' changes | Build | new | [Classic §1](notes/LIB-lightroom-classic.md#1-catalog-and-storage), [DAMs §4](notes/LIB-dams-and-open-source.md#4-recurring-complaints-ranked) |
| 7 | Nothing waits on file checks: folders listed once, network volumes in parallel, recent folders first, reads per volume from FastRawViewer's figures; unreachable volumes shown offline | Adopt | LIB-07 | [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp), [pro tools §5](notes/LIB-pro-tools.md#5-fastrawviewer) |
| 8 | Every sort, filter, count and duplicate check answered from the index | Build | LIB-10 | [pro tools §7](notes/LIB-pro-tools.md#7-recommendations-for-redlamp) |
| 9 | Search as you type over a million photos, with counts and no cap on results | Build | LIB-06 | [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp) |
| 10 | Indexing and analysis as visible, resumable, memory-capped background jobs | Build | LIB-07 | [culling §6](notes/LIB-culling-renaming-platform.md#6-recommendations-for-redlamp), [Classic §9](notes/LIB-lightroom-classic.md#9-ai-features) |
| 11 | Budgets for a million photos on SSD, spinning disk and SMB that fail on regression | Build | LIB-04 | [Classic §8](notes/LIB-lightroom-classic.md#8-scale-and-performance), [culling §4.1](notes/LIB-culling-renaming-platform.md#41-reported-sizes) |
| 12 | A grid tier for every photo and a capped screen tier, smaller than Photo Mechanic's proxies of about 340 KB, browsed from the store even when the originals are online | Do better | LIB-09 | [pro tools §3](notes/LIB-pro-tools.md#3-photo-mechanic-and-photo-mechanic-plus), [culling §6](notes/LIB-culling-renaming-platform.md#6-recommendations-for-redlamp) |
| 13 | The embedded preview at once, then Redlamp's render of the edit, marked so it's clear which is showing; previews made ahead and refreshed when stale | Adopt | LIB-17 | [pro tools §7](notes/LIB-pro-tools.md#7-recommendations-for-redlamp), [Classic §10](notes/LIB-lightroom-classic.md#10-recurring-complaints-ranked) |
| 14 | Lightroom Classic's single keys, Shift or Caps Lock to advance, a key for purple, and labels with the user's own names and colours | Adopt | LIB-15 | [Classic §2](notes/LIB-lightroom-classic.md#2-browsing-and-culling), [§4](notes/LIB-lightroom-classic.md#4-keywords-and-metadata) |
| 15 | A shortcut editor over the command list behind menus, palette and keys, with keymap presets for Lightroom Classic, Photo Mechanic and Bridge users; keys that never renumber | Do better | new | [Classic §7](notes/LIB-lightroom-classic.md#7-module-switching-and-keys), [pro tools §5](notes/LIB-pro-tools.md#5-fastrawviewer) |
| 16 | Undo for every culling, keyword, metadata, rename and move action | Do better | LIB-15, LIB-26 | [pro tools §6](notes/LIB-pro-tools.md#6-recurring-complaints-ranked), [culling §2.2](notes/LIB-culling-renaming-platform.md#22-preview-collisions-and-undo) |
| 17 | Sensor clipping and a raw histogram in the Library loupe | Adopt | new | [pro tools §5](notes/LIB-pro-tools.md#5-fastrawviewer) |
| 18 | One query language whose text and rule-editor forms convert into each other, with empty fields, relative dates and distance, AND, OR and EXCEPT, ranges and nested groups | Do better | LIB-06 | [pro tools §3](notes/LIB-pro-tools.md#3-photo-mechanic-and-photo-mechanic-plus), [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp) |
| 19 | Facets with counts, sorts on several fields, and saved filters kept with each source | Adopt | LIB-18 | [Classic §3](notes/LIB-lightroom-classic.md#3-search-and-smart-collections) |
| 20 | Smart collections kept current by the index and showing stacks; collections that refer to photos, not paths | Do better | LIB-23 | [Classic §3](notes/LIB-lightroom-classic.md#3-search-and-smart-collections), [pro tools §4](notes/LIB-pro-tools.md#4-adobe-bridge) |
| 21 | A keyword hierarchy with synonyms, export flags and category, private and person types; merging in one step; Lightroom keyword files without loss | Do better | LIB-21 | [Classic §4](notes/LIB-lightroom-classic.md#4-keywords-and-metadata), [DAMs §3.1](notes/LIB-dams-and-open-source.md#31-darktable-56-linux-macos-windows) |
| 22 | Photo Mechanic's metadata template (only the fields ticked, appended or prefixed) and code replacements | Adopt | LIB-22 | [pro tools §3](notes/LIB-pro-tools.md#3-photo-mechanic-and-photo-mechanic-plus) |
| 23 | Other apps' XMP read with priorities per field; `.xmp` written only when turned on and changed, labels in each app's names or as Urgency, rejects as −1, a shared `name.xmp` detected, and the result read back in Lightroom, Bridge and Photo Mechanic | Adopt | LIB-24 | [culling §3.1](notes/LIB-culling-renaming-platform.md#31-measurements), [pro tools §7](notes/LIB-pro-tools.md#7-recommendations-for-redlamp) |
| 24 | One naming grammar for renaming, import, export and capture: digiKam's tokens and modifiers, regular expressions, sub-second time, sequences per job, folder or extension, named counters kept across sessions | Do better | LIB-25 | [culling §2.1](notes/LIB-culling-renaming-platform.md#21-tokens), [DAMs §3.2](notes/LIB-dams-and-open-source.md#32-digikam-91-linux-macos-windows) |
| 25 | A full preview that flags empty tokens and orders collision suffixes by capture time; raw, JPEG, `.redlamp` and `.xmp` renamed together; the original name kept; a journal that survives a forced quit | Build | LIB-26 | [culling §2.2](notes/LIB-culling-renaming-platform.md#22-preview-collisions-and-undo), [§6](notes/LIB-culling-renaming-platform.md#6-recommendations-for-redlamp) |
| 26 | Photo Mechanic's ingest: several cards at once, two destinations, templates, photos already imported skipped, a start when a card is inserted, browsing while copying | Adopt | LIB-27 | [pro tools §3](notes/LIB-pro-tools.md#3-photo-mechanic-and-photo-mechanic-plus), [Classic §5](notes/LIB-lightroom-classic.md#5-import-and-renaming) |
| 27 | Copies verified before a card can be erased; imported photos recognised from file data and a partial hash before previews are read; a raw-only switch; decisions made on a card written at the destination | Build | LIB-27 | [pro tools §7](notes/LIB-pro-tools.md#7-recommendations-for-redlamp), [Classic §5](notes/LIB-lightroom-classic.md#5-import-and-renaming) |
| 28 | Stacks across folders, in every view, grouped by sub-second capture time and exposure length, then by similarity | Do better | LIB-28 | [Classic §2](notes/LIB-lightroom-classic.md#2-browsing-and-culling), [culling §6](notes/LIB-culling-renaming-platform.md#6-recommendations-for-redlamp) |
| 29 | Exact duplicates by hash in 1.0, similar photos from Vision's feature prints later; deletion only from an explicit, confirmed list | Do better | LIB-31 | [Classic §9](notes/LIB-lightroom-classic.md#9-ai-features), [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp) |
| 30 | Culling suggestions computed on the Mac from the decoded raw and face crops (open eyes and sharpness per face from Vision's landmarks), ranked within each scene with reasons, thresholds and a target count; nothing changed until accepted; the model's revision stored | Do better | OTH-02 | [culling §1](notes/LIB-culling-renaming-platform.md#1-ai-assisted-culling), [§6](notes/LIB-culling-renaming-platform.md#6-recommendations-for-redlamp) |
| 31 | Vision's labels and the text in photos as suggestions mapped onto the user's keywords | Adopt | LIB-32 | [culling §3](notes/LIB-culling-renaming-platform.md#3-apple-platform-capabilities-on-macos-26), [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp) |
| 32 | Natural-language search in which the model drafts, Redlamp's grammar parses dates and fields, values come from the index, and plain search works without the model | Do better | LIB-33 | [culling §3.1](notes/LIB-culling-renaming-platform.md#31-measurements) |
| 33 | People with thumbnails the user chooses, re-indexed by folder | Do better | LIB-34 | [Classic §4](notes/LIB-lightroom-classic.md#4-keywords-and-metadata) |
| 34 | A map on MapKit: pins aggregated in the index, place names looked up on demand and cached, track logs without a point limit | Build | LIB-35 | [culling §6](notes/LIB-culling-renaming-platform.md#6-recommendations-for-redlamp), [Classic §4](notes/LIB-lightroom-classic.md#4-keywords-and-metadata) |
| 35 | Metadata written into DNG, JPEG or TIFF files | Skip | LIB-24 | [Classic §6](notes/LIB-lightroom-classic.md#6-xmp-and-interop) |
| 36 | Live two-way sync with other apps' catalogs; read a copy instead | Skip | LIB-29, LIB-30 | [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp) |
| 37 | A shared multi-user database, or real-time multi-user sessions | Skip | new | [pro tools §7](notes/LIB-pro-tools.md#7-recommendations-for-redlamp), [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp) |
| 38 | Several catalogs, and merging them | Skip | new | [Classic §11](notes/LIB-lightroom-classic.md#11-recommendations-for-redlamp) |
| 39 | Culling analysis in the cloud | Skip | OTH-02 | [culling §6](notes/LIB-culling-renaming-platform.md#6-recommendations-for-redlamp) |
| 40 | Redlamp's own state stored as keywords | Skip | LIB-21 | [DAMs §3.1](notes/LIB-dams-and-open-source.md#31-darktable-56-linux-macos-windows) |

## 6. Open decisions and design points this informs

- **DEC-51, reading Lightroom Classic catalogs.** Capture One imports them and Peakto indexes them; Photo Mechanic can't, and asks Lightroom to write XMP first, which leaves collections, stacks and virtual copies behind. The evidence supports reading a copy; counsel's question stands ([pro tools §2](notes/LIB-pro-tools.md#2-capture-one), [DAMs §3.6](notes/LIB-dams-and-open-source.md#36-peakto-and-excire)).
- **`.xmp` names for raw and JPEG pairs** (a design open point). Capture One shares one `name.xmp` between `name.NEF` and `name.jpg`, darktable writes `name.ext.xmp`, and Lightroom reads `name.xmp` for raws and ignores sidecars for JPEGs. Redlamp can read both forms, write a raw's fields to `name.xmp`, and never let one photo's write remove the other's fields.
- **Collections in sidecars by path or by ID** (a design open point). The Lightroom Queen prefers keywords for lasting groupings because collections never reach the files, and Bridge's path-bound collections break when photos move. Both favour sidecars that describe themselves, as keywords by full path do: collections by path, renames rewriting sidecars through the journal.
- **DEC-50 and the map.** Nothing in the notes argues against keeping coordinates in the index on the Mac. The Map module's 58 Classic titles are mostly bugs in its Google map, and nothing ranks the map above the core, so it can stay after 1.0; Apple's geocoding is online and rate-limited, so place names should be looked up on demand and cached.

## 7. Proposed tracker changes

The owner accepted all of them on 5 October 2026: the new rows are LIB-36 to LIB-38, LIB-31's exact duplicates became LIB-39, and the skips are SKIP-18 to SKIP-20. Numbers in brackets are recommendations in section 5, which link the evidence.

**New rows**

- **A keyboard shortcut editor** (P4): every action in the command list reassignable, with keymap presets for Lightroom Classic, Photo Mechanic and Bridge users and conflicts shown (15; complaint 14).
- **Several Macs on one library** (P4): another Mac's sidecar changes, through iCloud Drive or a shared volume, picked up by change detection and merged field by field (keywords and collections as sets), extending AUD-01's iCloud merges to the library's fields (5, 6; complaint 4).
- **Sensor clipping in the Library loupe and Compare** (P4): UX-05's overlay and a raw histogram while culling, since the embedded JPEG hides clipping (17).

**Row to split**

- **LIB-31** into exact duplicates (P4: grouped by content key, confirmed by a full hash, reviewed in a view, and removed only to the Trash from an explicit list, with Undo) and similar photos (Later: Vision's feature prints through an index). Exact copies are quick to find by hash, while digiKam's all-pairs similarity search took 20 hours for 4% of 286,583 photos (29; complaint 16).

**Wording**

LIB-06 (4, 18), LIB-08 (3), LIB-11 (5), LIB-17 (13), LIB-18 (4, 19), LIB-21 (16, 21), LIB-22 (16, 22), LIB-23 (1, 20), LIB-24 (23), LIB-25 (24), LIB-26 (25), LIB-27 (26, 27, and `clonefile` never used for the backup copy), LIB-28 (1, 28), LIB-33 (32), LIB-34 (33), LIB-35 (34) and OTH-02 (30, depending on LIB-07 too). LIB-30 narrows to Capture One's catalogs and sessions and darktable's library, read from a copy, since Photo Mechanic's and Bridge's metadata comes through LIB-24 ([pro tools §3](notes/LIB-pro-tools.md#3-photo-mechanic-and-photo-mechanic-plus), [DAMs §5](notes/LIB-dams-and-open-source.md#5-recommendations-for-redlamp)).

**Recorded skips**

- A shared multi-user database or real-time multi-user sessions: the index is per Mac and rebuildable, and sidecars let a team share files (37).
- Several catalogs and merging them: a library of folders rebuilds its index and has nothing to merge (38).
- Live two-way sync with other apps' catalogs: private formats need an update for each of their releases (36).

The tracker's header would also list this study, with the source tag **LIB**.

## 8. Still open

- Where Lightroom's Assisted Culling runs; Adobe doesn't say.
- FSEvents on SMB and NFS volumes, as no network volume was mounted on the test Mac.
- Copy verification in Capture One and Photo Mechanic, which their documentation doesn't describe.
- Photo Mechanic Plus's claim to scroll a million photos, known only from a user quoting it.
- Adobe's own wording on the Library module, since its help site refused requests.
- Users' reports on IMatch (its forum refuses guests), and anything on DPReview or Reddit.

[lrc-ad2]: https://community.adobe.com/questions-675/early-access-assisted-culling-lrclassic-983825
[lrc-br7]: https://community.adobe.com/bug-reports-674/p-loses-connection-with-files-after-folder-is-renamed-662986
[lrc-br8]: https://community.adobe.com/bug-reports-674/p-message-the-catalog-could-not-be-opened-due-to-an-unexpected-error-662989
[lrc-br9]: https://community.adobe.com/bug-reports-674/p-after-the-new-version-update-today-unexpected-error-opening-catalog-663037
[lrc-br17]: https://community.adobe.com/bug-reports-674/p-delete-rejected-photos-in-duplicates-view-deletes-all-copies-1628661
[lrc-br18]: https://community.adobe.com/bug-reports-674/p-library-previews-not-updating-663816
[lrc-br22]: https://community.adobe.com/bug-reports-674/p-unable-to-advance-to-the-next-photo-664118
[lrc-f4]: https://www.lightroomqueen.com/community/threads/catalog-size.54801/
[lrc-f8]: https://www.lightroomqueen.com/community/threads/keyword-import-export-problem.50161/
[lrc-f12]: https://www.lightroomqueen.com/community/threads/my-catalog-is-corrupted-again.50298/
[lrc-f14]: https://www.lightroomqueen.com/community/threads/using-lightroom-on-two-machines.51636/
[lrc-fr1]: https://community.adobe.com/feature-requests-676/p-allow-catalog-to-be-stored-on-a-networked-drive-666362
[lrc-fr3]: https://community.adobe.com/feature-requests-676/p-include-additional-metadata-in-xmp-flags-collections-vc-s-etc-664991
[lrc-fr4]: https://community.adobe.com/feature-requests-676/p-allow-for-keyboard-shortcut-customization-666358
[lrc-fr6]: https://community.adobe.com/feature-requests-676/p-stacking-in-folders-and-collections-should-be-global-666404
[lrc-fr7]: https://community.adobe.com/feature-requests-676/p-better-auto-stacking-for-bracketing-hdr-focus-stacking-and-panoramas-666365
[lrc-fr12]: https://community.adobe.com/feature-requests-676/p-sort-by-more-fields-sort-by-multiple-fields-664750
[lrc-fr13]: https://community.adobe.com/feature-requests-676/p-better-keyword-management-666408
[lrc-fr18]: https://community.adobe.com/feature-requests-676/p-add-option-to-import-raw-only-665061
[lrc-fr19]: https://community.adobe.com/feature-requests-676/p-delete-images-on-card-after-import-666337
[lrc-qa1]: https://community.adobe.com/questions-675/experiencing-performance-related-issues-in-lightroom-4-x-987414
[lrc-qa2]: https://community.adobe.com/questions-675/how-do-i-remove-duplicates-in-my-lightroom-catalogue-952311
[pt-br-and]: https://community.adobe.com/questions-558/filtering-keywords-by-eliminating-170551
[pt-br-purple]: https://community.adobe.com/bug-reports-557/p-bridge-label-colours-keyboard-shortcut-options-1501472
[pt-br-rename-undo]: https://community.adobe.com/questions-558/add-undo-batch-rename-170434
[pt-br-unusable]: https://community.adobe.com/questions-558/whew-adobe-bridge-2026-v-16-03-21-is-unusable-1559675
[pt-c1-168]: https://support.captureone.com/hc/en-us/articles/35747427882653
[pt-c1-catalogs]: https://support.captureone.com/hc/en-us/articles/360003108698
[pt-c1-cull-edits]: https://support.captureone.com/hc/en-us/community/posts/11148235628829
[pt-c1-dam]: https://support.captureone.com/hc/en-us/community/posts/9826370590109
[pt-c1-dberror]: https://support.captureone.com/hc/en-us/articles/30493722534941
[pt-c1-dupes]: https://support.captureone.com/hc/en-us/community/posts/16125381142813
[pt-c1-labels]: https://support.captureone.com/hc/en-us/community/posts/10873231669405
[pt-c1-metadata]: https://support.captureone.com/hc/en-us/community/posts/10359022328861
[pt-c1-reject]: https://support.captureone.com/hc/en-us/community/posts/11213556068637
[pt-c1-renames]: https://support.captureone.com/hc/en-us/community/posts/17053816081565
[pt-c1-stacking]: https://support.captureone.com/hc/en-us/community/posts/11048240325021
[pt-c1-switching]: https://support.captureone.com/hc/en-us/articles/360003692438
[pt-c1-undo]: https://support.captureone.com/hc/en-us/community/posts/10060182640541
[pt-frv-grid]: https://www.fastrawviewer.com/node/1123
[pt-frv-keywords]: https://www.fastrawviewer.com/node/1262
[pt-frv-pick]: https://www.fastrawviewer.com/node/1226
[pt-pm-nas]: https://forums.camerabits.com/index.php?topic=15255.0
[pt-pm-sort]: https://forums.camerabits.com/index.php?topic=13301.0
[pt-pm-undo]: https://forums.camerabits.com/index.php?topic=17018.0
[pt-pm-withdrawn]: https://home.camerabits.com/photo-mechanic-plus-is-no-longer-available-for-purchase/
[dam-ap1]: https://support.apple.com/en-gb/guide/photos/pht1ed9b966d/mac
[dam-dk17]: https://discuss.kde.org/t/digikam-keeps-messing-up-network-share-albumb/32561
[dam-dk18]: https://discuss.kde.org/t/duplicate-search-takes-literally-days/21438
[dam-dk20]: https://discuss.kde.org/t/guidance-on-large-scale-multi-user-workflows-with-digikam/39657
[dam-dt14]: https://github.com/darktable-org/darktable/issues/21849
[dam-dt18]: https://github.com/darktable-org/darktable/issues/19728
[dam-dt22]: https://discuss.pixls.us/t/slow-image-import-to-a-large-library/22327
[dam-dx3]: https://forum.dxo.com/t/how-do-i-move-folders-around-without-getting-lost-images/49354
[dam-dx5]: https://forum.dxo.com/t/most-of-my-images-arent-worth-a-15-minute-loading-time/52236
[dam-im3]: https://www.photools.com/help/imatch/index.php?name=fw_basics.htm
[dam-im12]: https://www.photools.com/11908/imatch-performance-tips-for-large-photo-libraries/
[dam-or2]: https://www.on1.com/blog/browsing-vs-cataloging-the-ins-and-outs/
[dam-ps1]: https://www.idimager.com/photo-supreme-blog-articles/20k-160k-700k-photo-supreme-at-scale
[cul-as5]: https://support.aftershoot.com/en/articles/10570203-aftershoot-culling-genres
[cul-cb3]: https://forums.camerabits.com/index.php?topic=17023.0
[cul-cb4]: https://forums.camerabits.com/index.php?topic=12177.0
[cul-cb7]: https://forums.camerabits.com/index.php?topic=16440.0
[cul-cb8]: https://forums.camerabits.com/index.php?topic=15691.0
[cul-dt7]: https://discuss.pixls.us/t/solved-opening-db-from-lan-why-read-only/47238
[cul-n7]: https://help.narrative.so/en/articles/7337398-why-is-narrative-showing-a-high-focus-assessment-score-for-an-out-of-focus-image
[cul-n12]: https://help.narrative.so/en/articles/7337403-narrative-is-missing-faces-or-face-data
