# Katami, against the library track

Katami 1.1.0 (29 September 2026) is a raw photo browser for the Mac by Bespoke Byte: "your folders, not our catalog", with culling sessions, checks it calls Library Health, search, people, a map and export, and no editor ([KT1], [KT2], [KT4]). It sells for $79 once, on two Macs, with a year of updates and $39 for each year after; there is no trial, only a 14-day refund ([KT3]). This note reads its published features against the library track (LIB-01 to LIB-39, OTH-02, RM-02, FS-01) for what the library could take from it. Researched on 6 October 2026 from Katami's site; the app wasn't bought or run, so every claim about it is the vendor's own.

## Summary

- **Katami is the library's storage model sold on its own:** folders read in place, cards the only thing copied, everything analysed on the Mac. It confirms DEC-42 rather than challenging it.
- **Most of what it shows is already on the track,** built or planned: exact duplicates (LIB-39), pairs and bursts (LIB-28), import from cards with verified copies (LIB-27), search as you type with counts (LIB-06, LIB-18, LIB-19), smart collections (LIB-23), Compare (LIB-16), XMP for other apps (LIB-24), and its AI parts after 1.0 (LIB-31 to LIB-35, OTH-02).
- **What it does that the track doesn't plan** is mostly presentation and cheap measurement, not new machinery: findings shown as queues that appear only when there's a decision to make, each with its reason in words; bursts ranked by sharpness and missed focus found without a model; photos grouped into moments by time; a search that says which filter emptied it; named traits such as Long Exposure and Wide Open; focus peaking and the camera's AF point in the loupe; sensor dust followed from shoot to shoot.
- **Its site doesn't mention the library's core:** keywords, IPTC fields, renaming, moving, rule-based smart collections, other apps' XMP read back, Lightroom catalogs, a command line or any figure for scale. Its import copies a card into Pictures, with no templates or backup copy described ([KT2]).
- **Proposed** ([section 5](#5-proposed-tracker-changes)): five new rows (Library Health, moments and grouping, soft frames in bursts without a model, dust across shoots, Open With from Finder), wording for eight rows, and nothing recorded as a skip. They wait on the owner, and the soft-frame row on a measurement against the owner's own culls first ([section 6](#6-before-the-changes-are-accepted)).

## 1. Feature by feature

Verdicts: **Covered** (a row builds it), **Wording** (a row should say it), **Gap** (no row has it) and **Leave** (not worth taking).

| # | Katami ([KT2] unless marked) | Rows | The library track today | Verdict |
| --- | --- | --- | --- | --- |
| 1 | Folders, drives, cards and network shares read in place; nothing imported but cards | DEC-42, LIB-07, LIB-08 | The same model; sidecars can also live on this Mac for volumes Redlamp can't write (LIB-11) | Covered |
| 2 | Each source shows its state: online, offline (browsable as thumbnails, marked with its drive), moved, no access | LIB-08, LIB-09 | Offline photos browsed from the store; renames and moves found by file identity | Covered |
| 3 | A returning drive syncs automatically, after asking, or only when opened | LIB-08 | Reconciled automatically, the folders on screen first | Leave: an option worth having only if reconciling costs the user something, which the budgets (DEC-47) rule out |
| 4 | Sidebar entries that appear once they have something in them | LIB-23 | The Library panel's entries are named, not when they show | Wording, with Library Health ([section 3](#3-library-health)) |
| 5 | Recently Trashed: 30 days in the app, Put Back restoring the photo and its file | LIB-26, LIB-39 | Trash through the journal, with Undo; once Undo is gone, nothing lists what Redlamp put in the Trash | Gap, small |
| 6 | Hidden photos, locked behind Touch ID, and sensitive photos hidden automatically | — | — | Leave: a family-album feature, not a working photographer's |
| 7 | Albums in folders; an album that keeps its photos out of All Photos | LIB-23 | Collections and sets, saved in each photo's sidecar | Covered; Leave the exclusion, since a library of folders shows every photo it indexes |
| 8 | An album read as a whole: print size at 300 dpi, stacks, the days and bodies it spans, places, its palette, photos needing a second look, the space deleting it frees | LIB-23 | Not specified | Gap, small: a source's summary |
| 9 | Exact duplicates, verified byte for byte before anything moves | LIB-39 | Built on library/catalog | Covered |
| 10 | Raw and JPEG pairs as one photo, and one rule for pairs: keep both, the raw or the JPEG | LIB-27, LIB-28 | Pairs as one photo are built, and raw-only at import is designed; the JPEG halves of pairs already indexed can't be let go in one step | Gap, small |
| 11 | Similar shots and bursts ranked by sharpness, the sharpest suggested ("about 25 % softer than frame 2") | LIB-28, LIB-31, OTH-02 | Bursts found from the index are built; ranking is only in OTH-02, after 1.0 (DEC-46) | Gap: a ranking that needs no model can come before OTH-02 |
| 12 | Blurred: frames that missed focus, and which part of each resolved | FS-01, OTH-02 | FS-01 scores sharpness in a 6 × 4 grid of 256-pixel thumbnails; the AF point waits on FS-01's maker-note shim | Gap, with 11 |
| 13 | Over and under exposed: blown highlights and crushed shadows | UX-05, LIB-38 | Sensor clipping in Develop; planned for the Library loupe | Wording: as filters, not as a queue ([section 3](#3-library-health)) |
| 14 | Damaged files: empty, unreadable or half-copied | LIB-07, LIB-27 | Import verifies its copies; the indexer meets files it can't read, but nothing lists them | Gap, small |
| 15 | A file whose name says one format and holds another, renamed for it | LIB-07, LIB-26 | Not detected | Gap, small |
| 16 | Each check in the sidebar only while it has something to decide; no dashboard and no score; every finding says why; "this is fine, stop asking", which can be taken back | — | LIB-39's review proposes the copy to keep and why | Gap: the presentation, as Library Health |
| 17 | A card opens a session: how many frames, from which camera, which are already in the library; then copied into Pictures, checked file by file and ejected | LIB-27 | Built but for the window, the start on insertion and ejecting; Redlamp adds templates, a backup copy and a card that's safe to erase | Covered, and Redlamp's does more |
| 18 | Moments (frames taken together), runs inside them, setups when the backdrop and light change; views by lens and orientation | LIB-14, LIB-28, LIB-31 | Runs are LIB-28's bursts; nothing groups a list by gaps in time or by a field | Gap: grouping ([section 4](#4-moments-and-sessions)) |
| 19 | Proposals (one pick per moment, the best two, runs only), drawn dashed until accepted, never touching a frame the user decided; "Changed by you"; ⌘Z | OTH-02 | "Nothing changed until accepted" | Wording |
| 20 | The proposal walked full screen, one key per frame: Pick, Out, Alternate, Later; two loupes locked at 100% | LIB-15, LIB-16 | Flags, ratings and labels with auto-advance; Compare with synced zoom | Covered |
| 21 | Coverage: every setup with its picks, and how many have none | — | — | Gap, with 18 |
| 22 | Sensor dust checked first: how many spots, in how many frames, and whether they were there on an earlier shoot | RM-02 | Dust found and healed across a selection, by sensor place (built) | Gap: dust followed across shoots; Redlamp also heals it, where Katami shows it |
| 23 | Finishing: picks into an album, outs hidden or to the Trash, a "For the edit" list of lenses, ISO range, shutters and apertures, picks as 5★ and alternates as 3★ in XMP, a contact sheet PDF, decisions as CSV | LIB-12, LIB-23, LIB-24 | Collections, XMP and JSON from `redlamp library` | Covered, and the summary goes with 8; Leave the contact sheet, since print is out of scope |
| 24 | Nine judging tools on a key each: focus peaking or a focus map, the AF point, clipping (all, recoverable, truly clipped), zebra, exposure from −2 to +2 stops, waveform, RGB parade and vectorscope, false colour, black and white with filters, edge patrol; a loupe that follows the cursor at 100, 200 or 400%, tools included | UX-05, LIB-38 | Sensor clipping and the colour-assessment view, in Develop | Gap: peaking, the AF point and the loupe belong in LIB-38; the scopes are a separate question |
| 25 | Composition grids, aspect and cine frames, a level, guides drawn per photo | LNS-06 | Lightroom's crop overlays, in the Crop tool | Leave |
| 26 | A photo opened from Finder's Open With in a window of its own, with Import Folder when it deserves a place | UX-08 | Redlamp declares no document types, so it isn't offered in Open With | Gap, small, outside the library |
| 27 | Search as you type, offering the places, lenses, settings and things the library holds, with counts | LIB-06, LIB-18, LIB-19 | Planned | Covered |
| 28 | Saved searches | LIB-23 | Smart collections | Covered |
| 29 | A search that finds nothing names the filter standing in the way and offers to remove it | LIB-18 | — | Gap, small |
| 30 | Twenty traits worked out for each photo: Black & White, Long Exposure, Wide Open, Blown Highlights, Crushed Shadows, Low Light, Photos with Text, Best Shots, Smiling, One Person, Two People, Groups, Telephoto, Ultra Wide, Panoramas, Live Photos, Screenshots, High Resolution, No Location | LIB-06, LIB-32, LIB-34 | Fields and comparisons in the grammar; no named traits | Gap, small: those from EXIF in 1.0, the rest with LIB-32 and LIB-34 |
| 31 | Over a thousand kinds of object and scene, text in the frame, a caption for every photo from a downloaded model, all searchable | LIB-32, LIB-33 | After 1.0; image and text embeddings after a licence review | Covered (Later) |
| 32 | People found and grouped on the Mac; named, merged, ignored, and "this isn't them" | LIB-34 | After 1.0 | Wording |
| 33 | A map on Apple's MapKit; which photos have no location; Add Location written into the file, or an XMP sidecar where the file can't be rewritten safely | DEC-50, LIB-35 | After 1.0; writing into originals is a recorded skip (the study's recommendation 35) | Covered (Later), written to the sidecar |
| 34 | A list of everything that ever leaves the Mac, and when; place names looked up from Apple for every location in the background, each place once; a build test that fails if analytics are ever added ([KT2], [KT5]) | UX-10, LIB-35 | Report a Bug shows what's sent; the study advises looking places up on demand, since Apple's geocoding is rate-limited | Leave for the library; a note for the site |
| 35 | Export presets, ⇧⌘E with no dialog, watermarks, Edit With | EDT-15, EDT-16 | Export with Previous is done; batch export, watermarks and Edit In are planned for Phase 4 | Covered |
| 36 | When one way of reading a raw fails, another is tried; Foveon, GoPro GPR, Capture One EIP and QuickTake files open ([KT2], [KT4]) | CAM rows | — | Outside the library |

## 2. What it does better than Lightroom and the others

Against the [library study](../library-findings.md)'s products, on Katami's own account:

- **Decisions as queues.** Lightroom Classic gained a Duplicates view of exact matches only in 15.4 (June 2026), whose first build deleted photos it shouldn't have ([Classic §9](LIB-lightroom-classic.md#9-ai-features)), and none of the products studied gathers duplicates, damaged files, misnamed files, pair choices and soft frames in one place that empties as they're decided. The pieces exist elsewhere; the place doesn't.
- **Reasons in numbers relative to the shoot.** "About 25 % softer than frame 2" and "soft at the focus point, against the rest of the moment" judge a frame against its neighbours, where Lightroom's Assisted Culling and FilterPixel judge each frame on its own scale. Relative judgements are less exposed to the study's complaint 17 (AI culling misjudges outside portraits and on small previews), since a frame is only compared with frames of the same light, lens and subject.
- **Proposals that never overrule the photographer.** Narrative and Aftershoot propose too, but Katami's rule that a proposal never touches a frame the user decided, with the overruled frames listed under "Changed by you", is stated more plainly than in any of the five tools in the study's culling note.
- **An empty search explained.** No product in the study documents it.
- **Judging tools in the browser.** Of the study's products only FastRawViewer documents tools of this kind, for exposure read from the raw data (a raw histogram, clipping per channel, overlays) ([pro tools §5](LIB-pro-tools.md#5-fastrawviewer)); focus peaking, the AF point and scopes appear in none of the study's notes, and Lightroom has no waveform or vectorscope (not checked against Adobe's pages).
- **Dust followed across shoots.** None of the products studied tracks it; Redlamp's RM-02 already finds dust across a selection and heals it, which Katami doesn't claim.

## 3. Library Health

What Katami calls Library Health, scoped for Redlamp's library: checks that each produce a list of photos needing a decision, built from the index, the store and the indexer's one read per file ([design](../../plans/2026-10-05-library-design.md#indexing-lib-07)), with every action going through the file operations' journal (LIB-26). LIB-39's exact duplicates are its first check, and already built.

### 3.1 The checks

| Check | Found from | Proposes, and the reason shown | When it runs | Release |
| --- | --- | --- | --- | --- |
| Exact duplicates | Content key and size, then a full SHA-256 (LIB-39, built) | The copy to keep and why; "byte-identical to ‹path›" | Index-only, then the volumes' readers | 1.0 (LIB-39) |
| Raw and JPEG pairs | LIB-28's pairs, from the index | Nothing until the user picks a rule: keep both (the default), keep the raw, or keep the JPEG; then the halves the rule drops | Index-only | 1.0 |
| Damaged files | A new index state, `unreadable`, set when the indexer's read fails for any reason but a missing file or an offline volume (today it reports `LibraryIndexerEvent.failed` and keeps nothing); empty files from the listing; files that end early, where the header gives their length | "Empty"; "can't be read: ‹what the reader said›"; "ends 12 MB before its data does" | During indexing; the end-of-file reads in the background lane | 1.0 |
| Wrong extension | The first bytes, which the indexer reads anyway, against the extension's family | A rename to the right extension, with the sidecar, `.xmp` and pair following; "named .JPG, holds HEIC" | During indexing | 1.0 |
| Missing photos | LIB-08's `missing` state, already a filter (LIB-18) | What's there today: Locate… for a missing folder (UX-08), and sidecars left behind offered back to their photos (LIB-08) | Index-only | 1.0, wording |
| Soft frames in bursts | LIB-28's bursts; sharpness measured at the camera's focus point, from each frame's largest embedded preview | The sharpest frame of each burst; "about 25 % softer than frame 3 at the focus point" | Background lane, only for photos in bursts | The owner's call ([section 6](#6-before-the-changes-are-accepted)) |
| Sensor dust across shoots | RM-02's detector on a sample of each shoot's smooth frames, per camera body | The frames to heal; "4 specks, in 31 of 40 frames, first seen on 12 September" | Background lane, on request | After 1.0 |

- **Pairs:** a half with anything of its own (an edit, keywords, a title or caption, or a rating, flag or label that differs from the other half's) is listed apart, "the JPEG has its own edit", and left out of the rule unless chosen. The halves dropped go to the Trash with their own `.redlamp` and `.xmp`; a `name.xmp` the pair shares stays with the raw, so one half's removal never takes the other's fields (the study's open point on `.xmp` names).
- **Damaged files:** files still being written (`settling`) are never listed. Ending early is checked only where it costs no more than a small read: a JPEG's last two bytes (its end-of-image marker), the strip and tile offsets of TIFF-based raws (in the IFDs within the 256 KiB the indexer already reads) against the file's size, and an ISO base media file's top-level box sizes (CR3, HEIC) against its size. Nothing is repaired: Reveal in Finder, Move to Trash, or Keep Anyway.
- **Wrong extension:** most raws are TIFF inside, so only a mismatch between families counts (a `.jpg` holding TIFF or HEIC, a `.CR3` holding JPEG), never one TIFF-based raw's extension for another's. The confirmation says that other apps' catalogs pointing at the old name lose it.
- **Soft frames:** a grid thumbnail is too small to judge focus (the study found small embedded previews inflate Narrative's focus scores), so sharpness is measured on the largest embedded preview, at the AF point when the maker notes give it (FS-01's maker-note shim), else in the sharpest of FS-01's cells. Frames are compared only within their burst, never on an absolute scale. Results are derived: kept in an index table keyed by content key, rebuilt when the key changes, never in sidecars. This is the half of OTH-02 that needs no model; OTH-02 adds faces and open eyes.
- **Exposure and blur on their own** aren't checks: a high-key or deliberately soft photo needs no decision. They're traits in the query language instead ([section 5](#5-proposed-tracker-changes)).

### 3.2 How it's shown and decided

- **Only when there's something to decide.** The Library panel (LIB-23) gains a Library Health group listing each check that has findings, with its count; a check with none isn't shown, and the group goes when all are empty. No dashboard and no score. Each check is a source like any other (LIB-10), so the grid, the loupe, Compare and the filter bar work on it.
- **Proposals look like proposals.** A proposed keeper or drop is drawn apart from the user's own flags and never written as one; accepting it is a single batch through LIB-26, to the Trash only, which one Undo reverses.
- **Keep Anyway** takes a finding away and can be taken back from a Kept Anyway list. Dismissals live in `Definitions/Health.json`, beside the keyword definitions in `LibraryPaths.root`: keyed by the photo's content key and the check, and for duplicates by the group's SHA-256, so a third copy reopens the group. Not in sidecars: a dismissal changes nothing about the photo, works on volumes Redlamp can't write, and survives an index rebuild as the keyword definitions do (DEC-42).
- **Check Library Health** recounts every check: the index-only ones at once, the ones that read pixels queued in the background lane.
- **`redlamp library health`** lists the findings as `redlamp library duplicates` does, with JSON output (LIB-12).

### 3.3 What it never does

- Move, rename or remove anything without a confirmed list; delete rather than move to the Trash; or act on a photo the user rated, flagged or labelled because a proposal said so.
- Read every file again: each check uses the indexer's one read, the index or the store, except the end-of-file reads and the burst previews, which are small or limited to bursts, and run per volume in the background.
- Keep the interface waiting: the index-only checks keep LIB-39's budget (a million photos grouped in under a second, off the main thread), and counts change by diffs.

## 4. Moments and sessions

Katami's session is one shoot grouped into moments, a pick proposed for each, walked a frame at a time and finished into an album ([KT2]). For Redlamp it needn't be a new kind of thing: any source the library already has (a card being browsed for import, a folder, a collection, a search, a selection) shown in the grid grouped into moments, and walked in the loupe. No new module beside DEC-49's, and nothing new in sidecars.

### 4.1 Moments

- **Found from the column store** (LIB-06): the list's photos in capture order, a new moment starting where the gap to the previous frame is longer than both a floor and a multiple of the typical gap around it, so a wedding shot every few seconds and a landscape walk shot every few minutes both split where the photographer paused. The floor and the multiple are a single Tighter–Looser control on the list; their defaults are for the measurement in [section 6](#6-before-the-changes-are-accepted) to set, starting from 60 seconds and four times the median of the 20 gaps around.
- **Runs inside a moment** are LIB-28's bursts, as found today. **Setups** (Katami's "the backdrop and light changed") need pixel similarity, so they come with LIB-31's feature prints, after 1.0.
- **Two bodies at one event** are one moment when their clocks agree; Group by Moment and Camera splits them when they don't. Capture times come from the index as they are, so the design's open point on time zones (EXIF's offset tags, else the Mac's zone at import) decides how two bodies' times compare.
- **Deterministic:** the same photos and setting always give the same moments, with ties broken by capture time and then name, so a rebuilt index gives them back.
- **Budget:** one pass over sorted times, off the main thread, as stacks are found; LIB-28's budgets apply (under 1 s for a million photos, a moment opened or closed under 2 ms, every moment opened or closed under 50 ms, with diffs).

### 4.2 Grouping in the grid

- **Group By** on any list in the grid (LIB-14): none, moment, day, folder, camera, lens, orientation. Each group has a header with its count and how many of its photos are picks, and opens and closes as stacks do.
- **Coverage:** the list says how many moments have no pick, and that number filters to them, so a moment shot once isn't lost in the cull.
- **The source's summary** (row 8 of section 1): the days, bodies, lenses, and the ISO, shutter and aperture ranges the list spans, its pairs and stacks, from the column store; Katami's "For the edit" list is this summary of the picks.

### 4.3 Proposals and the walk

- **Proposals** come from Library Health's soft-frame check while there's no model (the sharpest frame of each run, the sharpest at its AF point in each moment) and from OTH-02 after it: one pick per moment, the best two, or runs only.
- **A decided frame is never touched.** A frame with a flag, rating or label keeps it whatever is proposed; a proposal is drawn dashed until accepted; Accept writes flags as one batch with Undo (LIB-15); and **Changed by You**, the frames where the user's decision differs from the proposal, is a filter.
- **The walk** is the loupe: ← and → by frame, ⌥← and ⌥→ by moment, Lightroom's P, X and U (LIB-15), C to compare a moment's two best at 100% (LIB-16). Katami's Alternate is a rating the user chooses (3 stars by default, as Katami writes alternates to XMP) and its Later is no flag, so the states stay the ones Lightroom, Capture One and Photo Mechanic read (LIB-24).
- **Finishing** is ordinary: the picks into a collection named after the source (LIB-23), rejects left to the Rejected source or moved to the Trash through LIB-26 when asked.

### 4.4 What's stored

- **Decisions** are flags, ratings and labels in each photo's sidecar, as everywhere (DEC-42).
- **Moments, runs and proposals** are derived: computed for the list, proposals kept with the soft-frame results in the index, by content key, and none of it in sidecars.
- **The grouping and its Tighter–Looser setting** are part of the source's view, which LIB-14 already remembers for each source; a session worth keeping is a collection or a smart collection with that view.
- **A card** is LIB-27's browsing before copying, grouped into moments from the capture times its preview reads give; the choices made are written at the destination, as designed.

## 5. Proposed tracker changes

For the owner to accept, as the study's section 7 was; none is in the tracker yet. New rows are named "new", since their IDs are given when they're added (the library's next is LIB-40 today). Numbers in brackets are rows of section 1.

**New rows**

- **Library Health** (P4, M, Do better; after LIB-10, LIB-23, LIB-26, LIB-39): the checks of [section 3](#3-library-health) that read no pixels, LIB-39's duplicates first: a rule for raw and JPEG pairs, damaged files (a new `unreadable` index state, empty files, files that end early), wrong extensions and missing photos; each shown only while it has findings, with its reason in words; proposals drawn apart and acted on only as a confirmed batch to the Trash, with Undo; Keep Anyway in `Definitions/Health.json`; `redlamp library health` (9, 10, 14, 15, 16).
- **Moments and grouping** (P4, M, Adopt; after LIB-06, LIB-14, LIB-28): Group By in the grid (moment, day, folder, camera, lens, orientation), moments from gaps in capture time with a Tighter–Looser control, the moments without a pick, and a source's summary; cards browsed for import grouped the same way ([section 4](#4-moments-and-sessions); 8, 18, 21).
- **Soft frames in bursts, without a model** (P4 or after 1.0, the owner's call once [section 6](#6-before-the-changes-are-accepted)'s measurement is in; M, Build; after LIB-28 and Library Health, and FS-01's maker-note shim for the AF point): the sharpest frame of each burst and moment at the camera's focus point, from the largest embedded preview, judged only against its own burst, proposed as one pick per moment, the best two or runs only, never touching a frame the user decided, with Changed by You (11, 12, 19). Split from OTH-02.
- **Sensor dust followed across shoots** (after 1.0, S, Build; after RM-02 and LIB-07): RM-02's detector on a sample of each shoot's smooth frames, per camera body (the body's serial number, which the index doesn't keep yet), with when each speck first appeared and the frames to heal (22). RM-02's own row is another session's; this one only uses its detector.
- **Open With from Finder** (Phase 2, S, Adopt; outside the library, so the orchestrator's call): Redlamp declares the raw and image types it opens, so Finder's Open With offers it and it can be the default; a photo opened that way shows in its folder, as File › Open does today (26).

**Wording**

- **LIB-06:** traits, named shorthands in the grammar, each a query over indexed fields and offered in completion with counts: Long Exposure (shutter of a second or more), Panorama (2:1 or wider), High Resolution, Low Light (ISO 3200 or more), No Location (`-has:gps`); Wide Open, Telephoto and Ultra Wide need the lens's widest aperture and the 35 mm-equivalent focal length, which the index adds as columns; Photos with Text, One Person, Two People, Groups and Smiling come with LIB-32 and LIB-34 (13, 30).
- **LIB-18:** when a query finds nothing, the filter bar names the term whose removal brings back the most photos and offers to remove it: one count per term from the column store, cancelled when the query changes (29).
- **LIB-23:** the Library panel's entries appear once they hold photos, Library Health's checks among them; a collection or any source shows its summary (4, 8).
- **LIB-26:** Recently Trashed, a source of what Redlamp moved to the Trash, from the journal, with Put Back for as long as the files are still in the Trash, after Undo is gone (5).
- **LIB-34:** a face can be ignored, two people merged, and a photo taken out of a person, "this isn't them" (32).
- **LIB-38:** the Library loupe's judging tools: sensor clipping and the raw histogram, as now, with focus peaking, the camera's AF point (FS-01's maker-note shim) and a loupe that follows the pointer at 100, 200 and 400% with the overlays on (24).
- **OTH-02:** what needs a model (faces and open eyes, expressions, a model's ranking across a scene), on top of the soft-frame row's proposals and with their rules: a decided frame never touched, proposals drawn apart until accepted, Changed by You (19).
- **FS-01:** the maker-note shim gives the AF point too, for the soft-frame check and the Library loupe (12, 24).

Waveforms, RGB parades, vectorscopes, false colour and zebra (24) are a question for Develop as much as for the library, and none of the study's notes finds them in a photo browser, so they're left for the owner to raise rather than proposed.

**The README and the comparison,** once rows are accepted (`.cursor/rules/roadmap-and-comparison.mdc`):

- README, Phase 4: "Files on disk" gains damaged and misnamed files and a rule for raw and JPEG pairs (Library Health); "Grid and culling" gains photos grouped into moments (Moments and grouping), and the soft frames if they're in 1.0. After 1.0, "The library's AI and map" gains dust across shoots.
- `docs/lightroom-comparison.md`, Library and organising: "Duplicates" widens to Library Health (Lightroom: Partly, exact duplicates since 15.4); new rows for grouping into moments and for soft frames found in bursts (the Lightroom column to be checked: Lightroom Classic's Assisted Culling judges sharpness, but whether it ranks a burst isn't documented in the study), and "Sensor clipping while culling" becomes judging tools while culling.

## 6. Before the changes are accepted

The rows that read no pixels (Library Health, moments) follow from the study's evidence and cost little. The soft-frame row is the one whose value isn't known: a sharpest-frame proposal is useful only if it agrees with what the photographer would pick. So before it's placed in 1.0 or after, it's measured on three shoots the owner has already culled, with the picks and rejects as the owner made them (in Lightroom's XMP or Redlamp's sidecars, which the index reads, LIB-24):

| Scenario | What it is | What it measures |
| --- | --- | --- |
| An event | 1,000 frames or more, bursts, people, ideally two bodies | Moment boundaries the owner agrees with, of 50 drawn at random; in each burst, whether the sharpest frame at the AF point is the owner's pick; how often it would set aside a frame the owner picked |
| Travel | Several days, mixed light, long pauses, one body, raw and JPEG pairs | Moments where shooting is sparse; pairs found against the folder's own count; how many of the owner's rejects the traits (Low Light, Long Exposure) or the soft-frame check explain |
| Portraits | A studio or location session, backdrop and light changes, raw and JPEG | How much grouping by lens and orientation stands in for setups before LIB-31; how many of the owner's rejects sharpness explains, and how many need open eyes or expression (OTH-02) |

Proposed thresholds, for the owner to set: the soft-frame row goes into 1.0 if its proposal is the owner's pick in at least 70% of bursts and would set aside an owner's pick in under 10%; the moments' defaults stand if 45 of the 50 boundaries are right in each scenario. The measurement is a script beside the library's prototypes (`research/prototypes/`), reading the index and the store; timing a whole cull against today's filmstrip waits until the grouping exists.

## 7. Left

- **A choice of when a returning drive syncs** (3): reconciling costs the user nothing within the budgets.
- **Hidden photos behind Touch ID, and sensitive photos hidden automatically** (6): for family albums more than for working photographers.
- **Albums that keep their photos out of All Photos** (7): a library of folders shows every photo it indexes.
- **The contact sheet PDF** (23): print is out of scope.
- **Composition grids in the loupe** (25): the Crop tool has Lightroom's overlays.
- **A list of what leaves the Mac** (34): not the library's to show, though the website could say it as plainly; Katami's build test that fails if analytics are added is worth knowing about.
- **Its business model:** $79 with a year of updates is Katami's; Redlamp is free and open source, and the library is part of it.

## Sources

Read on 6 October 2026. Katami's pages render their demonstrations in the browser; the text was read from the pages as served.

- [KT1] Katami, home page. <https://katami.io/>
- [KT2] Katami, Everything it does. <https://katami.io/features>
- [KT3] Katami, Pricing. <https://katami.io/pricing>
- [KT4] Katami, Release notes, 1.0.1 to 1.1.0. <https://katami.io/updates>
- [KT5] Katami, Privacy. <https://katami.io/legal/privacy>
