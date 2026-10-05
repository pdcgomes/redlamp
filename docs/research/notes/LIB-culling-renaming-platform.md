# Library research: AI culling, renaming tools, Apple platform APIs and library scale

Evidence for the library study (LIB-01): what the AI culling tools judge, how renaming tools build names (the benchmark for LIB-25 and LIB-26), which macOS 26 APIs the library would use, and how large libraries get and how they behave on NAS, SMB and spinning disks.

Sources were checked on 5 October 2026; vendor claims are labelled as such. Three measurements ran on an Apple M1 Ultra with macOS 26.6.2 and the macOS 26.5 SDK while other builds were running (load average 15 to 24), so their timings are indicative; the scripts ran from standard input and were not kept. Citations such as [[N1]] link to the source, and [Sources](#sources) lists every link.

## Summary

- The culling tools judge the same things (focus, eyes open, faces and expressions, near-duplicates) and differ in presentation: tiers with reasons, buckets with a target, scores, or thresholds.
- Narrative, Aftershoot and Excire analyse on the computer (Lightroom Classic too, by a competitor's account); FilterPixel's genre model runs in its cloud.
- Embedded previews make analysis quick but mislead when small: Narrative's focus scores run high on small Sony previews.
- Background analysis of a whole catalogue is where culling breaks: Lightroom Classic 15.4's re-analysis crashed for one user and leaked memory until 15.5.
- No renaming tool we could check documents undo of a completed batch rename (Adobe's help was not reachable); ABFR saves the old and new names so they can be replayed.
- digiKam's grammar has regular expressions, unique suffixes and sequences scoped by folder or extension; Lightroom Classic 15.0's templates had no sub-second time.
- Vision gives 1,303 fixed labels, feature prints, aesthetics and face quality at 10 to 30 ms per preview, but none of them ordered a near-identical series.
- Foundation Models always returned a well-formed query but misread dates and invented or dropped fields in seven tests: it can draft a query, not decide one.
- ImageIO's XMP round trip kept other apps' fields but rewrote the layout, so writing `.xmp` should stay opt-in and happen only on change.
- FSEvents history is kept per volume and replays from a stored event ID and database UUID; Apple does not say whether network volumes report other computers' changes.
- Catalogues of 1 to 2 million photos exist in Photo Mechanic Plus, Lightroom Classic and digiKam, and each vendor whose advice we found says to keep the database on a local disk.
- What helped on slow storage was a local preview of every photo and no network access from the interface thread.

## 1. AI-assisted culling

### 1.1 The tools

| Tool and version | What it judges | Where it runs | Speed | Pricing |
|---|---|---|---|---|
| Narrative Select (help pages 2025–2026) | Scenes ranked in five tiers, from "Best in scene" to "Undesirable", with reasons [[N2]] [[N4]]; eyes open and focus for each face [[N5]]; a 1–10 focus score [[N6]] | On the computer, offline; nothing uploaded [[N8]] [[N9]] | Vendor: raw import in seconds [[N1]]; analysis takes seconds to tens of minutes, longer on mechanical drives [[N10]] | $10 to $60 a month; ranking from the $20 plan [[N3]] |
| Aftershoot Select (Oct 2026) | A 1–100 score from over 30 factors (sharpness, exposure, blinks, expression); buckets for selects, highlights, closed eyes, blur and duplicates; genres; a 10–60 % target [[AS2]] [[AS3]] [[AS4]] [[AS5]] | On the computer, offline [[AS1]] [[AS3]] | Vendor: 20–30 minutes a shoot, review included [[AS2]] | $10 a month billed yearly, or $15 month to month [[AS2]] |
| FilterPixel (Oct 2026) | Blur, blinks, expressions, duplicates; DeepCull scores for a genre, with a reason [[FP1]] [[FP2]] | DeepCull on its cloud GPUs, online only [[FP3]] [[FP4]]; the basic cull unstated (unverified) | Vendor: about 8 minutes per 1,000 photos [[FP5]] | $14.99 to $64.99 a month billed yearly, with 20 to 140 DeepCull shoots a year [[FP3]] |
| Lightroom Classic Assisted Culling (early access in 15.0, Oct 2025; general in 15.4, Jun 2026) | Subject focus, eye focus and eyes-open thresholds with a "can't tell" class [[PP2]] [[LQ4]]; per-face scores [[LQ5]] [[AD1]]; stacks by time or similarity [[PP2]] | Not stated by Adobe; locally according to FilterPixel (unverified) [[FP6]] | No Adobe figure; one user's re-analysis of 71,031 photos crashed repeatedly in 15.4 [[LQ5]]; memory leaks fixed in 15.5 [[LQ6]] | In the subscription (prices not checked) |
| Excire Foto 2027 (16 Jun 2026) | Scenes, sequences, similarity; sharpness including the eyes, eyes open, expressions; aesthetics; duplicates [[EX1]] [[EX2]] [[PP3]] | On the computer [[EX1]] [[PP3]] | No figures published | $249 perpetual, paid upgrades [[EX2]] [[EX3]] |

Adobe announced its criteria in June 2025 [[PP1]]. Its scores have since changed with model updates for group portraits (15.2) and shallow depth of field (15.3) [[LQ3]] [[LQ4]], and are recalculated after edits such as crops [[LQ2]]. A separate duplicate finder in 15.4 may take hours to index a catalogue [[LQ5]].

### 1.2 How photographers use them

- **As a first pass.** Some Narrative users pick only from the top two tiers; others hide the bottom tier first [[N4]]. Narrative, Aftershoot and FilterPixel delete nothing [[N4]] [[AS3]] [[FP1]].
- **Before the editor.** Aftershoot advises culling before importing into Lightroom or Capture One [[AS4]]. Ratings and labels travel in XMP sidecars, or inside JPEGs [[N11]] [[AS3]].
- **Per genre.** Aftershoot suggests turning closed-eye detection off for boudoir and newborn work, and has it off by default for sports, where helmets hide eyes [[AS5]].
- **With caution.** The Lightroom Queen warns that culling during import makes it easy to format a card before everything is imported, and a landscape photographer found 15.0's culling suited to portraits only [[LQ1]].

**Assessment.** The judgements are common to all five; presentation and where the work runs differ. The recurring failures are small previews [[N7]], missed faces [[N12]], the wrong genre [[AS5]] [[LQ1]] and background analysis of a whole catalogue [[LQ5]] [[LQ6]].

## 2. Renaming tools

Versions: A Better Finder Rename (ABFR) 12.35, for macOS 15 and later [[BR1]]; Photo Mechanic's current documentation [[PM1]]; digiKam 9.2.0 [[DK1]]; darktable 5.6 [[DT1]]. Adobe's help could not be reached, so Bridge comes from a Bridge CS6 tutorial (2014, revised 2022) [[BG1]] and Lightroom Classic from secondary sources dated 2016 to 2025 [[LT1]] [[LT2]] [[LT3]] [[LQ1]]. A dash means the sources read do not document the feature.

### 2.1 Tokens

| | ABFR 12.35 | Bridge (CS6) | Photo Mechanic | Lightroom Classic | digiKam 9.2 | darktable 5.6 |
|---|---|---|---|---|---|---|
| Capture date and time | EXIF dates, time zones [[BR1]] | Date Time: creation or modification date [[BG1]] | `{year4}`, `{month0}`, `{day0}`, `{hour}` and more [[PM2]] | Many formats, including day of the year [[LT1]] [[LT2]] | `[date:format]` [[DK1]] | `$(EXIF.YEAR)` to `$(EXIF.SECOND)` [[DT1]] |
| Sub-second | Orders bursts by it [[BR10]] | — | `{subsecond}` [[PM2]] | Not as of 15.0 [[LQ1]] | `zzz` [[DK1]] | `$(EXIF.MSEC)` [[DT1]] |
| Camera, lens, exposure | Camera and lens tags [[BR2]] | A metadata element (fields unverified) | `{model}`, `{lenstype}`, `{iso}`, `{shutter}` and more [[PM2]] | Metadata tokens (fields unverified) [[LT1]] | `[cam]`, `[meta:key]` [[DK1]] | `$(MODEL)`, `$(LENS)`, `$(EXIF.ISO)` and more [[DT1]] |
| Original name, folder | The current name [[BR1]] | Current name; original saved in XMP [[BG1]] | `{filenamebase}`, `{frame4}`, `{folder}` [[PM2]] | Filename, number suffix, folder; preserved name since 8.3 [[LT1]] [[LT3]] | `[file]`, `[dir]`, `[dir.]` [[DK1]] | `$(FILE.NAME)`, `$(FILE.FOLDER)` [[DT1]] |
| Sequence and scope | A start value, or ten counters shared by all actions and kept across sessions [[BR4]] | Start and digits [[BG1]] | `{seqn}`, kept across ingest, rename and upload, plus named counters; `{ingestseq}` per card [[PM3]] | Import # and Image # (catalogue-wide), Sequence # (per run), Total # [[LT1]] | `#` with start and step; per folder, per extension, continuing the highest, or random [[DK1]] | `$(SEQUENCE[n,m])` per job [[DT1]] |
| Other metadata | Location tags [[BR1]] | Unverified | IPTC, rating, colour class, GPS, lookup tables [[PM2]] | IPTC [[LT1]] | EXIF, IPTC, XMP, database fields [[DK1]] | Any XMP tag, keywords, stars, labels, GPS [[DT1]] |
| Case | Yes, including by word class [[BR9]] | — | Lower, upper, proper [[PM4]] | Extension only [[LT1]] | `{upper}`, `{lower}`, `{firstupper}` [[DK1]] | `^^`, `,,` and first-letter forms [[DT1]] |
| Substrings, replacement | Yes [[BR1]] | Unverified | `{var:index,count}`, find and replace [[PM4]] | — | `{range}`, `{replace}`, `{trim}`, `{default}` [[DK1]] | Substrings, prefix and suffix removal, replace, defaults [[DT1]] |
| Regular expressions | Yes [[BR1]] | Unverified | — | — | `{replace:…,r}` [[DK1]] | None, by design [[DT1]] |

### 2.2 Preview, collisions and undo

| | Preview | Collisions | Undo |
|---|---|---|---|
| ABFR | Live, changes highlighted; a file missing a tag's data keeps its name, greyed [[BR1]] [[BR2]] | Automatic; suffixes ordered by capture date, modification date, then name [[BR3]] | —; the old and new names can be saved and replayed [[BR5]] [[BR6]] |
| Bridge | One example, old and new [[BG1]] | Unverified | Unverified |
| Photo Mechanic | The next counter value [[PM5]] | Add the sequence [[PM5]]; Copy/Move can overwrite [[PM6]] | — |
| Lightroom Classic | One example [[LT2]] | Unverified | Unverified |
| digiKam | Old and new names of all files [[DK1]] | `{unique}` adds a suffix [[DK1]] | — |
| darktable | — | Export: unique name, overwrite or skip [[DT3]] | —; files in the library are renamed only by the `rename_images` Lua script [[DT4]] |

darktable's variables also name the folders and files of copied imports [[DT2]]. ABFR 12 moves a raw, its JPEG and its sidecars together [[BR8]]. Lightroom Classic 15.0 displays capture milliseconds, but its templates still could not use them, so bursts need numeric suffixes [[LQ1]]. ABFR's developer reports that the Finder in macOS 26 pads sequence numbers to five digits (unverified) [[BR7]].

**Assessment.** No tool we could check combines regular expressions, sub-second time, scoped sequences, file pairing, a full preview, deterministic collision handling and undo.

## 3. Apple platform capabilities on macOS 26

| Capability (first macOS) | In Redlamp's library | Limits |
|---|---|---|
| `ClassifyImageRequest` (15) [[AP1]] [[AP2]] | Keyword suggestions (LIB-32) | 1,303 fixed labels in revision 2 (measured), with `wedding`, `beach` and `people` but no `sunset`, `portrait` or `landscape`; thresholds per label |
| `GenerateImageFeaturePrintRequest` (15) [[AP3]] | Similar photos, duplicates, stacks (LIB-31, LIB-28) | 768 floats (measured); a bare distance that needs tuned cut-offs; store the revision |
| `CalculateImageAestheticsScoresRequest` (15) [[AP4]] | A culling hint; `isUtility` sets aside receipts and screenshots | One opaque score from −1 to 1 |
| `DetectFaceCaptureQualityRequest` (15) [[AP5]] [[AP6]] | The best frame of one person | Comparable only between frames of the same subject, never against a threshold |
| `RecognizeTextRequest` (15), `RecognizeDocumentsRequest` (26) [[AP7]] [[AP8]] | Searchable text in photos (LIB-32) | 30 languages (measured) |
| `DetectLensSmudgeRequest` (26) [[AP9]] | Flag smudged phone shots | Motion blur and long exposures can score as smudges |
| Foundation Models: `@Generable`, `DynamicGenerationSchema` (26) [[AP10]] [[AP12]] | A sentence turned into a query (LIB-33), with values limited to the index | Macs that support Apple Intelligence (M1 and later), with it on and the model ready [[AP14]] [[AP15]]; 4,096 tokens per session [[AP13]]; the model changed in 26.4 and changes in 27 [[AP11]] |
| MapKit: `MKReverseGeocodingRequest` (26), clustering (10.13) [[AP16]] [[AP18]] | Map view, search by place (LIB-35) | `CLGeocoder`, deprecated in 26, describes geocoding as online and rate-limited, about one request per user action [[AP17]]; clustering merges colliding views, so a million pins need aggregating first |
| ImageIO: `CGImageMetadataCreateFromXMPData`, `CGImageMetadataCreateXMPData`, `CGImageDestinationCopyImageSource` (10.8) [[AP19]] [[AP20]] | Read other apps' XMP; write `.xmp` (LIB-24), with the `xmp:LabelColor` that Lightroom Classic 15.0 added [[LQ1]] | Apple suggests sidecars for raws [[AP19]]; lossless rewriting only for some formats; custom prefixes must be registered [[AP20]] |
| FSEvents (10.5; file IDs 10.13) [[AP21]] | Replay changes at launch (LIB-08); follow renames by file ID [[AP24]] | Pair the event ID with the volume's database UUID, which travels with the volume; read-only volumes have no history [[AP22]]; a new UUID, wrapped IDs or a "must scan" flag mean a rescan [[AP21]] [[AP26]]; `no_log` turns history off [[AP25]]; avoid recursive scans of non-local volumes when they mount [[AP23]]; network coverage undocumented (unverified) |
| `clonefile(2)`, `COPYFILE_CLONE` (10.12) [[AP27]] | Stress-harness libraries (LIB-03); instant copies on one volume | Same volume and supporting file systems only; a clone shares blocks, so it is not a backup, and later writes can fail with `ENOSPC` |

### 3.1 Measurements

- **Vision.** Eight CC0 Nikon Z 6 raws of one still-life scene, shot over 85 seconds at identical settings (`tests/fixtures/shoots/nikon-z6`), analysed from their embedded previews at 1,024 px. Per photo: preview 78 ms, classification 29 ms, feature print 12 ms, aesthetics 10 ms, face quality 17 ms. Distances between neighbouring feature prints were 0.000 to 0.004 and aesthetics scores 0.59 to 0.62: the frames grouped but were not ordered. A million photos would take about 40 hours on one serial queue.
- **Foundation Models.** Seven sentences through a `@Generable` query type were always well formed [[AP12]] but often wrong: "last summer" became June to August 2025, "this year" became today, and a wedding search gained a camera and the place "Boston". With optional fields, the rating and camera landed in the free text and the flags were dropped. Each request took 1 to 18 seconds.
- **XMP.** Parsing a packet with `crs:`, `lr:`, `photomechanic:` and `dc:` properties, changing `xmp:Rating` and serialising it kept every value and list order, but turned attributes into elements, reordered properties and changed the toolkit string; a second packet lost its `<?xpacket?>` wrapper.

**Assessment.** Vision groups and hints but does not rank; Foundation Models drafts queries for the user to check; MapKit needs aggregation in our index; ImageIO is adequate for reading XMP and for opt-in writing; FSEvents covers local volumes.

## 4. Library sizes and network storage

### 4.1 Reported sizes

| App | Library | Hardware and storage | Outcome | Source |
|---|---|---|---|---|
| Lightroom Classic | About 2,000,000 | Not stated | Works; slowdowns depend on hardware | [[LQ8]], Dec 2019 |
| Lightroom Classic | 240,000 | Not stated | Sluggish after an update | [[LQ8]], Dec 2019 |
| Photo Mechanic Plus | 1,000,000 test catalogue; users up to 1,600,000; a trial user's 1,500,000 | Not stated | No limit and no speed complaints, says Camera Bits | [[CB1]], Apr 2022; [[CB2]], Nov 2024 |
| Photo Mechanic Plus | First 100,000 of over 1,000,000 | Mac | Ten hours; 34 GB of 1,600-px proxies and a 2.2 GB database | [[CB1]], Apr 2022 |
| Photo Mechanic Plus | 300,000 of a larger archive | NAS | A six-hour scan, then two or more days of processing, the app unusable meanwhile | [[CB4]], Apr 2019 |
| Photo Mechanic Plus | About 250,000 | Local | The catalogue database corrupted; restored from Time Machine | [[CB7]], Oct 2024 |
| digiKam | Over 1,000,000 | SQLite in WAL mode on SSD or NVMe | Works, according to long-time users | [[DK2]], 9.2.0 |
| darktable 3.4 | 183,000; over 389,000 | Ryzen 7 2700X, 32 GB; i7-970, 36 GB, spinning disk | 128 photos imported in 113 s, against 4 s into an empty library; 185 in 161 s against about 10 s | [[DT5]], Jan 2021 |
| darktable 4.2 | 356,000 in 265 folders | NFS, Linux, 32 GB | Freezes of 1 to 30 seconds, even on local files | [[DT6]], Feb 2023 |

### 4.2 What was slow, what broke, what helped

- **Slow.** Photos on a NAS work in Lightroom but can be slow over the connection, so the Lightroom Queen suggests NAS units for backups [[LQ9]] [[LQ10]]. Synology disks that have spun down add a wait [[DT6]], and mechanical drives slow Narrative [[N10]]. The Finder's `.DS_Store` reads slow SMB browsing [[AP28]]; Apple's packet-signing advice applies only to macOS 10.13.3 and earlier [[AP29]]. Reopening a 22,000-photo folder made Photo Mechanic re-read files at 200 MB/s for minutes, adding 0.75 s to each rating [[CB3]]. A missing index slowed darktable's imports as its library grew [[DT5]].
- **Broke.** SQLite on network shares: darktable on CIFS reported "database is locked" [[DT7]], and digiKam rules it out [[DK2]]. Lightroom catalogues cannot live on network drives, and disk-image workarounds can corrupt them [[LQ10]] [[LQ11]]. Camera Bits says never to put a catalogue on a NAS [[CB5]] and supports only local catalogues [[PM7]]. Apple advises against Photos libraries on network storage, and Photos opens a new, empty library when its drive is missing [[AP30]]. darktable rechecked every folder on each mount change, so an NFS automount that kept remounting froze it [[DT6]]. Sharing a Photo Mechanic catalogue between two Macs needs a disconnect or repair at each switch [[CB8]].
- **Helped.** A local database with previews of everything: Lightroom smart previews on an SSD [[LQ9]], Photo Mechanic proxies for offline media [[PM8]], darktable's local copies [[DT8]]. Turning proxies off for an always-present NAS kept a catalogue near 20 GB [[CB5]]; a longer NFS timeout ended darktable's freezes [[DT6]]; an added index cut its import time by about 30 % [[DT5]]. SQLite's WAL mode carried digiKam users past 1,000,000 items [[DK2]]. digiKam keeps a trash folder in each collection because the desktop trash is slow for network collections [[DK1]]. A 10 GbE network was fast enough for one user [[CB8]]. A 2020 request for local proxies on slow network mounts is still open [[CB6]].

**Assessment.** Million-photo libraries exist, and the database is always local. Tools stayed usable when they showed slow volumes from local previews, and froze when the interface touched those volumes directly.

## 5. Recurring complaints, ranked by how often we saw them

1. **Databases on network storage are slow, locked or corrupted** (six sources): [[LQ10]] [[LQ11]] [[CB5]] [[DK2]] [[DT7]] [[AP30]].
2. **Background analysis or indexing makes the app slow or unstable** (five): [[LQ5]] [[LQ6]] [[LQ7]] [[CB4]] [[N10]].
3. **Indexing a large library takes hours or days** (four): [[CB1]] [[CB4]] [[DT5]] [[LQ5]].
4. **AI judgements fail outside portraits, on small previews or with hidden faces** (four): [[LQ1]] [[AS5]] [[N7]] [[N12]].
5. **Catalogues cannot be shared between computers, or become corrupt** (three): [[CB7]] [[CB8]] [[LQ10]].
6. **Views that read files instead of an index stall on slow storage** (two): [[CB3]] [[DT6]].
7. **Names cannot tell burst frames apart because templates lack sub-second time** (two): [[LQ1]] [[BR10]].

## 6. Recommendations for Redlamp

Culling (OTH-02, after 1.0):

- **Adopt** ranking within each scene with the reasons shown, strict-to-cautious presets and a target count: the tools converged on it, and it leaves the decision with the photographer [[N4]] [[AS4]].
- **Do better** by judging sharpness on Redlamp's decoded raw, with full-resolution face crops, not on embedded previews that mislead when small [[N7]].
- **Build** eyes-open and per-face sharpness from Vision's landmarks: Vision returns no eyes-closed result [[AP31]], and face quality only ranks one person's frames [[AP6]].
- **Do better** at grouping: capture time to the sub-second first, feature prints second, since the prints grouped our series but could not order it (§3.1).
- **Adopt** suggestions that delete nothing and touch no sidecar until accepted, stored with the model revision, because scores shift between versions [[LQ3]] [[LQ4]].
- **Build** analysis as a visible, resumable, memory-capped background job that yields to the photographer [[LQ5]] [[CB4]].
- **Skip** cloud analysis: it breaks the on-device rule, and Narrative, Aftershoot and Excire show that local analysis works [[N8]] [[AS3]] [[EX1]].

Renaming (LIB-25, LIB-26):

- **Do better** with one grammar for renaming, import, export and tethering that has darktable's string operations, digiKam's modifiers and regular expressions, and sub-second time (§2.1).
- **Adopt** explicit sequence scopes: per job, folder or extension, continuing the highest number, and named counters kept across sessions [[DK1]] [[PM3]] [[BR4]].
- **Adopt** file pairing, extended to `.redlamp` and `.xmp`, because a raw renamed without its sidecar loses its ratings [[BR8]] [[N11]].
- **Adopt** a full preview that highlights changes, flags empty tokens and offers defaults, with collision suffixes ordered by capture time [[BR2]] [[BR3]] [[DK1]].
- **Build** a journaled rename that can be undone and survives a forced quit; none of the documentation we read describes one (§2.2).
- **Adopt** storing the original name in metadata, as Bridge and Lightroom Classic do, so renames stay reversible [[BG1]] [[LT3]].

Platform and scale:

- **Adopt** Vision's labels and text recognition as suggestions mapped onto the user's keywords, because the label set is fixed (§3).
- **Do better** at natural-language search: the model drafts, our own grammar parses dates and attributes, values come from the index, the tokens stay editable, and plain search remains when the model is unavailable (§3.1).
- **Build** map aggregation in the index, with place names looked up on demand and cached, because Apple's geocoding is online and rate-limited [[AP17]].
- **Adopt** FSEvents per volume with the event ID and UUID stored, file IDs and targeted rescans; poll network volumes until FSEvents is tested on them [[AP21]] [[AP22]].
- **Adopt** ImageIO for XMP, writing `.xmp` only when turned on and changed, and checking that Lightroom, Bridge and Photo Mechanic read it back (§3.1).
- **Adopt** `clonefile` for the stress harness and same-volume copies, never as the backup copy on import [[AP27]].
- **Build** the index, previews and journals on the Mac's own disk, browse slow and offline volumes from previews, and check folders off the interface thread [[DT6]] [[CB5]] [[DK2]].
- **Do better** on preview size than Photo Mechanic, whose proxies averaged about 340 KB (about 340 GB per million photos), with a small grid tier and a capped screen tier [[CB1]].

## Sources

All checked 5 October 2026. Dates are the page's own where it gives one.

**Narrative**

- [N1] Narrative Select, AI-assisted culling page. <https://narrative.so/select>
- [N2] AI First Pass feature page. <https://narrative.so/features/ai-culling-first-pass>
- [N3] Pricing. <https://narrative.so/pricing>
- [N4] Help: AI First Pass Image Assessments (4 Sep 2026). <https://help.narrative.so/en/articles/7337372-ai-first-pass-image-assessments>
- [N5] Help: Face and Focus Assessments (15 Dec 2025). <https://help.narrative.so/en/articles/7337369-face-and-focus-assessments>
- [N6] Help: Filter by Focus Score (15 Dec 2025). <https://help.narrative.so/en/articles/7337374-filter-by-focus-score>
- [N7] Help: why a high focus score for an out-of-focus image (22 May 2025). <https://help.narrative.so/en/articles/7337398-why-is-narrative-showing-a-high-focus-assessment-score-for-an-out-of-focus-image>
- [N8] Help: What happens to my images and data with Narrative? (22 May 2025). <https://help.narrative.so/en/articles/7337413-what-happens-to-my-images-and-data-with-narrative>
- [N9] Help: Can I use Narrative offline? (8 Dec 2025). <https://help.narrative.so/en/articles/7337406-can-i-use-narrative-offline>
- [N10] Help: Narrative is running slowly or is unresponsive (22 May 2025). <https://help.narrative.so/en/articles/7337397-narrative-is-running-slowly-or-is-unresponsive-what-can-i-do>
- [N11] Help: What are .XMP (sidecar) files and why does Narrative use them? (22 May 2025). <https://help.narrative.so/en/articles/7337368-what-are-xmp-sidecar-files-and-why-does-narrative-use-them>
- [N12] Help: Narrative is missing faces or face data (22 May 2025). <https://help.narrative.so/en/articles/7337403-narrative-is-missing-faces-or-face-data>

**Aftershoot**

- [AS1] Home page. <https://aftershoot.com/>
- [AS2] Select (culling) page, with pricing and FAQ. <https://aftershoot.com/selects/>
- [AS3] Support: Technical Answers About Aftershoot. <https://support.aftershoot.com/en/articles/10601968-technical-answers-about-aftershoot>
- [AS4] Support: Get Started with Aftershoot Culling (3 Sep 2026). <https://support.aftershoot.com/en/articles/5223473-get-started-with-aftershoot-culling>
- [AS5] Support: Aftershoot Culling Genres (12 Sep 2025). <https://support.aftershoot.com/en/articles/10570203-aftershoot-culling-genres>

**FilterPixel**

- [FP1] Home page. <https://filterpixel.com/>
- [FP2] Culling page and FAQ. <https://filterpixel.com/culling>
- [FP3] Pricing (redirects to accounts.filterpixel.com). <https://filterpixel.com/pricing>
- [FP4] FilterPixel vs Aftershoot (vendor comparison). <https://filterpixel.com/filterpixel-vs-aftershoot>
- [FP5] FilterPixel vs Narrative Select (vendor comparison). <https://filterpixel.com/filterpixel-vs-narrative-select>
- [FP6] Lightroom AI vs FilterPixel (vendor comparison). <https://filterpixel.com/lightroom-ai-vs-filterpixel>

**Lightroom Classic** (the Lightroom Queen is a secondary source)

- [LQ1] What's new in Lightroom Classic 15.0 (Oct 2025), with comments of 28–29 Oct 2025. <https://www.lightroomqueen.com/whats-new-in-lightroom-2025-10/>
- [LQ2] … 15.1 (Dec 2025). <https://www.lightroomqueen.com/whats-new-in-lightroom-2025-12/>
- [LQ3] … 15.2 (Feb 2026). <https://www.lightroomqueen.com/whats-new-in-lightroom-2026-02/>
- [LQ4] … 15.3 (Apr 2026). <https://www.lightroomqueen.com/whats-new-in-lightroom-2026-04/>
- [LQ5] … 15.4 (Jun 2026), with comments of 19 Jun 2026. <https://www.lightroomqueen.com/whats-new-in-lightroom-2026-06/>
- [LQ6] … 15.5 (Aug 2026), bug fixes. <https://www.lightroomqueen.com/whats-new-in-lightroom-2026-08/>
- [LQ7] … 15.6 (Sep 2026), bug fixes. <https://www.lightroomqueen.com/whats-new-in-lightroom-2026-09/>
- [LQ8] Lightroom Catalogs: Top 10 Misunderstandings, comments of 17–18 Dec 2019. <https://www.lightroomqueen.com/lightroom-catalogs-top-10-misunderstandings/>
- [LQ9] Lightroom performance: computer hardware, with comments. <https://www.lightroomqueen.com/lightroom-performance-computer-hardware/>
- [LQ10] How to use a Lightroom catalog on multiple computers, with comments. <https://www.lightroomqueen.com/how-to-lightroom-catalog-multiple-computers/>
- [LQ11] Is it safe to store a Lightroom catalog on the new Dropbox macOS beta? <https://www.lightroomqueen.com/catalog-on-dropbox-beta/>
- [AD1] Adobe blog, From culling to compositing (15 Jun 2026). <https://blog.adobe.com/en/publish/2026/06/15/from-culling-to-compositing-new-creative-cloud-innovations-across-every-stage-of-your-workflow>
- [PP1] PetaPixel, Adobe is developing AI-powered culling tools for Lightroom (17 Jun 2025). <https://petapixel.com/2025/06/17/adobe-is-developing-ai-powered-culling-tools-for-lightroom/>
- [PP2] PetaPixel, Lightroom's new features: AI culling and more (3 Nov 2025). <https://petapixel.com/2025/11/03/lightrooms-new-features-ai-culling-auto-dust-removal-color-variance-slider-and-more/>

**Excire**

- [EX1] Excire Foto 2027 product page and FAQ. <https://excire.com/en/excire-foto/>
- [EX2] Excire Foto 2027 Is Here (release date and prices). <https://excire.com/en/excire-foto-2027-is-here/>
- [EX3] Shop (licence terms). <https://excire.com/en/shop/>
- [PP3] PetaPixel, Excire Foto 2025 promises to speed up photo culling (6 Dec 2024). <https://petapixel.com/2024/12/06/excire-foto-2025-promises-to-dramatically-speed-up-photo-culling-and-organization/>

**A Better Finder Rename**

- [BR1] Official site, version 12.35. <https://www.publicspace.net/ABetterFinderRename/index.html>
- [BR2] Manual: tag-based renaming. <https://www.publicspace.net/ABetterFinderRename/v12/TagBasedRenaming.html>
- [BR3] Manual: conflict resolution options; what a file name conflict is. <https://www.publicspace.net/ABetterFinderRename/v12/FileNameConflictResolutionOptions.html>, <https://www.publicspace.net/ABetterFinderRename/v12/FileNameConflicts.html>
- [BR4] Manual: auto-increment counters. <https://www.publicspace.net/ABetterFinderRename/v12/AutoIncrementCounters.html>
- [BR5] Manual: saving file lists; renaming from a file list. <https://www.publicspace.net/ABetterFinderRename/v12/SavingFileLists.html>, <https://www.publicspace.net/ABetterFinderRename/v12/RenameFromFileList.html>
- [BR6] Version history (11.00 beta 6, 1 Jul 2019: undo for edits in the multi-step interface). <https://www.publicspace.net/ABetterFinderRename/version.html>
- [BR7] Developer's blog: rename photos with sequence numbers (Sep 2026). <https://www.publicspace.net/blog/rename-photos-sequence-numbers/>
- [BR8] Manual: file pairing. <https://www.publicspace.net/ABetterFinderRename/v12/FilePairing.html>
- [BR9] Manual: lexical case conversion. <https://www.publicspace.net/ABetterFinderRename/v12/LexicalCaseConversion.html>
- [BR10] Developer's blog: rename photos by date taken (bursts and time zones). <https://www.publicspace.net/blog/rename-photos-by-date-taken-mac/>

**Adobe Bridge and Lightroom Classic naming** (secondary sources)

- [BG1] Photoshop Essentials, How to batch rename images with Adobe Bridge (Bridge CS6; 21 May 2014, revised 7 Dec 2022). <https://www.photoshopessentials.com/essentials/how-to-batch-rename-images/>
- [LT1] Sean McCormack, Tips for file renaming success in Lightroom, Digital Photography School (2 Jul 2016, revised 26 Nov 2020). <https://digital-photography-school.com/tips-for-file-renaming-success-in-lightroom/>
- [LT2] Scott Kelby, Advanced naming options in Lightroom Classic, Lightroom Killer Tips (7 May 2021). <https://lightroomkillertips.com/advanced-naming-options-in-lightroom-classic/>
- [LT3] The Lightroom Queen, What's new in Lightroom Classic since version 6 (8.3: preserved filename). <https://www.lightroomqueen.com/whats-new-lightroom-classic-since-version-6/>

**Photo Mechanic** (Camera Bits documentation)

- [PM1] Introduction to variables. <https://docs.camerabits.com/support/solutions/articles/48000207639-introduction-to-variables-in-photo-mechanic>
- [PM2] List of Photo Mechanic variables. <https://docs.camerabits.com/support/solutions/articles/48000358438-list-of-photo-mechanic-variables>
- [PM3] The sequence variable. <https://docs.camerabits.com/support/solutions/articles/48001205803-the-sequence-variable>
- [PM4] Variable substring extraction. <https://docs.camerabits.com/support/solutions/articles/48001077381-variable-substring-extraction>
- [PM5] Rename Photos tool. <https://docs.camerabits.com/support/solutions/articles/48001141415--rename-photos-tool>
- [PM6] Copy/Move Photos tool. <https://docs.camerabits.com/support/solutions/articles/48000223598-copy-move-photos-tool>
- [PM7] Catalog management (local catalogues only; proxies). <https://docs.camerabits.com/support/solutions/articles/48001179060-catalog-management>
- [PM8] Offline or missing media; introduction to Photo Mechanic Plus catalogs. <https://docs.camerabits.com/support/solutions/articles/48001162818-offline-or-missing-media>, <https://docs.camerabits.com/support/solutions/articles/48001078324-introduction-to-photo-mechanic-plus-catalogs>

**Camera Bits forum**

- [CB1] Maximum catalog size in Photo Mechanic Plus (15–16 Apr 2022). <https://forums.camerabits.com/index.php?topic=14953.0>
- [CB2] Scroll a million (4–7 Nov 2024). <https://forums.camerabits.com/index.php?topic=16484.0>
- [CB3] File reading behavior in large contact sheets (13–14 Nov 2025). <https://forums.camerabits.com/index.php?topic=17023.0>
- [CB4] Rapid flashing / slow cataloging / external drives (24 Apr 2019). <https://forums.camerabits.com/index.php?topic=12177.0>
- [CB5] Photo Mechanic 6+ and large database of imagery (29–30 Dec 2020). <https://forums.camerabits.com/index.php?topic=13855.0>
- [CB6] Prefer local proxies for slow network mounts (2020–2021). <https://forums.camerabits.com/index.php?topic=14400.0>
- [CB7] Unable to open catalog (7–8 Oct 2024). <https://forums.camerabits.com/index.php?topic=16440.0>
- [CB8] Real database backend as an option (10–11 Jun 2023). <https://forums.camerabits.com/index.php?topic=15691.0>

**digiKam and darktable**

- [DK1] digiKam 9.2.0 manual, image view: renaming and deleting photographs; the Batch Queue Manager uses the same rules. <https://docs.digikam.org/en/main_window/image_view.html>, <https://docs.digikam.org/en/batch_queue/queue_settings.html>
- [DK2] digiKam 9.2.0 manual, database settings. <https://docs.digikam.org/en/setup_application/database_settings.html>
- [DT1] darktable 5.6 manual, variables. <https://docs.darktable.org/usermanual/5.6/en/special-topics/variables/>
- [DT2] darktable 5.6 manual, import module (naming rules). <https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/lighttable/import/>
- [DT3] darktable 5.6 manual, export module (on conflict). <https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/shared/export/>
- [DT4] darktable Lua scripts manual, rename_images. <https://docs.darktable.org/lua/stable/lua.scripts.manual/scripts/contrib/rename_images/>
- [DT5] pixls.us, Slow image import to a large library (5–6 Jan 2021). <https://discuss.pixls.us/t/slow-image-import-to-a-large-library/22327>
- [DT6] darktable issue 13569, darktable intermittently hangs with a NAS connection (8 Feb 2023), and the pixls.us thread that led to it (5–8 Feb 2023). <https://github.com/darktable-org/darktable/issues/13569>, <https://discuss.pixls.us/t/performance-issue-with-nas/35174>
- [DT7] pixls.us, Opening DB from LAN: why read-only? (26–31 Dec 2024). <https://discuss.pixls.us/t/solved-opening-db-from-lan-why-read-only/47238>
- [DT8] darktable 5.6 manual, local copies. <https://docs.darktable.org/usermanual/5.6/en/overview/sidecar-files/local-copies/>

**Apple** (developer documentation read through the DocC JSON under developer.apple.com/tutorials/data/documentation/)

- [AP1] ClassifyImageRequest; supportedIdentifiers. <https://developer.apple.com/documentation/vision/classifyimagerequest>, <https://developer.apple.com/documentation/vision/classifyimagerequest/supportedidentifiers>
- [AP2] ClassificationObservation. <https://developer.apple.com/documentation/vision/classificationobservation>
- [AP3] GenerateImageFeaturePrintRequest; FeaturePrintObservation.distance(to:). <https://developer.apple.com/documentation/vision/generateimagefeatureprintrequest>, <https://developer.apple.com/documentation/vision/featureprintobservation/distance(to:)>
- [AP4] CalculateImageAestheticsScoresRequest; overallScore; isUtility. <https://developer.apple.com/documentation/vision/calculateimageaestheticsscoresrequest>, <https://developer.apple.com/documentation/vision/imageaestheticsscoresobservation/overallscore>, <https://developer.apple.com/documentation/vision/imageaestheticsscoresobservation/isutility>
- [AP5] DetectFaceCaptureQualityRequest. <https://developer.apple.com/documentation/vision/detectfacecapturequalityrequest>
- [AP6] WWDC19 session 222, Understanding Images in Vision Framework (transcript). <https://developer.apple.com/videos/play/wwdc2019/222/>
- [AP7] RecognizeTextRequest. <https://developer.apple.com/documentation/vision/recognizetextrequest>
- [AP8] RecognizeDocumentsRequest. <https://developer.apple.com/documentation/vision/recognizedocumentsrequest>
- [AP9] DetectLensSmudgeRequest. <https://developer.apple.com/documentation/vision/detectlenssmudgerequest>
- [AP10] Foundation Models. <https://developer.apple.com/documentation/foundationmodels>
- [AP11] Foundation Models updates (Feb, Mar and Jun 2026). <https://developer.apple.com/documentation/updates/foundationmodels>
- [AP12] Generating Swift data structures with guided generation. <https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation>
- [AP13] Managing the context window. <https://developer.apple.com/documentation/foundationmodels/managing-the-context-window>
- [AP14] SystemLanguageModel.Availability. <https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum>
- [AP15] Apple Intelligence (supported Macs). <https://www.apple.com/apple-intelligence/>
- [AP16] MKReverseGeocodingRequest; MKGeocodingRequest. <https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest>, <https://developer.apple.com/documentation/mapkit/mkgeocodingrequest>
- [AP17] CLGeocoder (deprecated in 26; usage guidance). <https://developer.apple.com/documentation/corelocation/clgeocoder>
- [AP18] MKClusterAnnotation; clusteringIdentifier. <https://developer.apple.com/documentation/mapkit/mkclusterannotation>, <https://developer.apple.com/documentation/mapkit/mkannotationview/clusteringidentifier>
- [AP19] CGImageMetadataCreateXMPData; CGImageMetadata; CGImageMetadataCreateFromXMPData; CGMutableImageMetadata. <https://developer.apple.com/documentation/imageio/cgimagemetadatacreatexmpdata(_:_:)>, <https://developer.apple.com/documentation/imageio/cgimagemetadata>, <https://developer.apple.com/documentation/imageio/cgimagemetadatacreatefromxmpdata(_:)>, <https://developer.apple.com/documentation/imageio/cgmutableimagemetadata>
- [AP20] CGImageDestinationCopyImageSource, and the comments in `CGImageDestination.h` and `CGImageMetadata.h` in the macOS 26.5 SDK. <https://developer.apple.com/documentation/imageio/cgimagedestinationcopyimagesource(_:_:_:_:)>
- [AP21] File System Events (API collection and event flags). <https://developer.apple.com/documentation/coreservices/file_system_events>, <https://developer.apple.com/documentation/coreservices/file_system_events/1455361-fseventstreameventflags>
- [AP22] FSEventsCopyUUIDForDevice. <https://developer.apple.com/documentation/coreservices/1444453-fseventscopyuuidfordevice>
- [AP23] kFSEventStreamEventFlagMount. <https://developer.apple.com/documentation/coreservices/kfseventstreameventflagmount>
- [AP24] kFSEventStreamEventExtendedFileIDKey. <https://developer.apple.com/documentation/coreservices/kfseventstreameventextendedfileidkey>
- [AP25] File System Events Programming Guide (updated 13 Dec 2012): persistent events; security and `no_log`. <https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/FileSystemEventSecurity/FileSystemEventSecurity.html>, <https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html>
- [AP26] `FSEvents.h` in the macOS 26.5 SDK (Xcode 26.6), read locally; no web copy.
- [AP27] `clonefile(2)` and `copyfile(3)` manual pages on macOS 26.6.2 (`man 2 clonefile`, `man 3 copyfile`), read locally; no web copy.
- [AP28] Apple Support, Adjust SMB browsing behavior in macOS (29 Feb 2024). <https://support.apple.com/en-us/102064>
- [AP29] Apple Support, Turn off packet signing for SMB 2 and SMB 3 connections (archived). <https://support.apple.com/en-us/101442>
- [AP30] Apple Support, Move your Photos library to save space on your Mac. <https://support.apple.com/en-us/108345>
- [AP31] FaceObservation (landmarks, pitch, roll, yaw and capture quality; no eyes-closed property). <https://developer.apple.com/documentation/vision/faceobservation>

## Not reached

- `helpx.adobe.com` (HTTP 403): Lightroom Classic's Assisted Culling and file-naming help, and Bridge's Batch Rename help. Adobe's own statement on where Assisted Culling runs, and Bridge's string substitution, regular expressions, collisions and undo, remain unverified.
- `www.adobe.com`, `business.adobe.com` and `adobe.com/community` (connection failed; `community.adobe.com` redirects there), including the Lightroom Classic idea thread on milliseconds in naming templates, known here only from [[LQ1]].
- `reddit.com` (its search API returned 403; pages returned only a script challenge).
- `www.dpreview.com` search, news listings, forums and sitemap (403); `www.fredmiranda.com` forum (403); `photo.stackexchange.com` (403); `photographylife.com` search (403); `bhphotovideo.com` Explora search (403); `support.captureone.com` (403), so Capture One is absent from §4.
- `www.lightroomqueen.com/community` search (403, a Cloudflare challenge); the blog and its comments were reachable.
- `petapixel.com` search and tag pages (403); the PetaPixel articles cited were found in the site's own sitemap and read directly.
- `excire.zendesk.com` (help centre closed, 403); `support.excire.com` (its knowledge base renders only with JavaScript); `help.aftershoot.com` (no connection; Aftershoot's help is at `support.aftershoot.com`, used above); `www.johnbeardy.com` (no connection).
- Web search: `html.duckduckgo.com` (202 challenge), `www.google.com` (needs JavaScript) and `search.brave.com` (challenge) refused, and `www.bing.com` returned unrelated results, so sources were found by site navigation, the sites' own search and sitemaps.
- Not tested: FSEvents on an SMB or NFS volume, because none was mounted on the test Mac.

[N1]: https://narrative.so/select
[N2]: https://narrative.so/features/ai-culling-first-pass
[N3]: https://narrative.so/pricing
[N4]: https://help.narrative.so/en/articles/7337372-ai-first-pass-image-assessments
[N5]: https://help.narrative.so/en/articles/7337369-face-and-focus-assessments
[N6]: https://help.narrative.so/en/articles/7337374-filter-by-focus-score
[N7]: https://help.narrative.so/en/articles/7337398-why-is-narrative-showing-a-high-focus-assessment-score-for-an-out-of-focus-image
[N8]: https://help.narrative.so/en/articles/7337413-what-happens-to-my-images-and-data-with-narrative
[N9]: https://help.narrative.so/en/articles/7337406-can-i-use-narrative-offline
[N10]: https://help.narrative.so/en/articles/7337397-narrative-is-running-slowly-or-is-unresponsive-what-can-i-do
[N11]: https://help.narrative.so/en/articles/7337368-what-are-xmp-sidecar-files-and-why-does-narrative-use-them
[N12]: https://help.narrative.so/en/articles/7337403-narrative-is-missing-faces-or-face-data
[AS1]: https://aftershoot.com/
[AS2]: https://aftershoot.com/selects/
[AS3]: https://support.aftershoot.com/en/articles/10601968-technical-answers-about-aftershoot
[AS4]: https://support.aftershoot.com/en/articles/5223473-get-started-with-aftershoot-culling
[AS5]: https://support.aftershoot.com/en/articles/10570203-aftershoot-culling-genres
[FP1]: https://filterpixel.com/
[FP2]: https://filterpixel.com/culling
[FP3]: https://filterpixel.com/pricing
[FP4]: https://filterpixel.com/filterpixel-vs-aftershoot
[FP5]: https://filterpixel.com/filterpixel-vs-narrative-select
[FP6]: https://filterpixel.com/lightroom-ai-vs-filterpixel
[LQ1]: https://www.lightroomqueen.com/whats-new-in-lightroom-2025-10/
[LQ2]: https://www.lightroomqueen.com/whats-new-in-lightroom-2025-12/
[LQ3]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-02/
[LQ4]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-04/
[LQ5]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-06/
[LQ6]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-08/
[LQ7]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-09/
[LQ8]: https://www.lightroomqueen.com/lightroom-catalogs-top-10-misunderstandings/
[LQ9]: https://www.lightroomqueen.com/lightroom-performance-computer-hardware/
[LQ10]: https://www.lightroomqueen.com/how-to-lightroom-catalog-multiple-computers/
[LQ11]: https://www.lightroomqueen.com/catalog-on-dropbox-beta/
[AD1]: https://blog.adobe.com/en/publish/2026/06/15/from-culling-to-compositing-new-creative-cloud-innovations-across-every-stage-of-your-workflow
[PP1]: https://petapixel.com/2025/06/17/adobe-is-developing-ai-powered-culling-tools-for-lightroom/
[PP2]: https://petapixel.com/2025/11/03/lightrooms-new-features-ai-culling-auto-dust-removal-color-variance-slider-and-more/
[EX1]: https://excire.com/en/excire-foto/
[EX2]: https://excire.com/en/excire-foto-2027-is-here/
[EX3]: https://excire.com/en/shop/
[PP3]: https://petapixel.com/2024/12/06/excire-foto-2025-promises-to-dramatically-speed-up-photo-culling-and-organization/
[BR1]: https://www.publicspace.net/ABetterFinderRename/index.html
[BR2]: https://www.publicspace.net/ABetterFinderRename/v12/TagBasedRenaming.html
[BR3]: https://www.publicspace.net/ABetterFinderRename/v12/FileNameConflictResolutionOptions.html
[BR4]: https://www.publicspace.net/ABetterFinderRename/v12/AutoIncrementCounters.html
[BR5]: https://www.publicspace.net/ABetterFinderRename/v12/SavingFileLists.html
[BR6]: https://www.publicspace.net/ABetterFinderRename/version.html
[BR7]: https://www.publicspace.net/blog/rename-photos-sequence-numbers/
[BR8]: https://www.publicspace.net/ABetterFinderRename/v12/FilePairing.html
[BR9]: https://www.publicspace.net/ABetterFinderRename/v12/LexicalCaseConversion.html
[BR10]: https://www.publicspace.net/blog/rename-photos-by-date-taken-mac/
[BG1]: https://www.photoshopessentials.com/essentials/how-to-batch-rename-images/
[LT1]: https://digital-photography-school.com/tips-for-file-renaming-success-in-lightroom/
[LT2]: https://lightroomkillertips.com/advanced-naming-options-in-lightroom-classic/
[LT3]: https://www.lightroomqueen.com/whats-new-lightroom-classic-since-version-6/
[PM1]: https://docs.camerabits.com/support/solutions/articles/48000207639-introduction-to-variables-in-photo-mechanic
[PM2]: https://docs.camerabits.com/support/solutions/articles/48000358438-list-of-photo-mechanic-variables
[PM3]: https://docs.camerabits.com/support/solutions/articles/48001205803-the-sequence-variable
[PM4]: https://docs.camerabits.com/support/solutions/articles/48001077381-variable-substring-extraction
[PM5]: https://docs.camerabits.com/support/solutions/articles/48001141415--rename-photos-tool
[PM6]: https://docs.camerabits.com/support/solutions/articles/48000223598-copy-move-photos-tool
[PM7]: https://docs.camerabits.com/support/solutions/articles/48001179060-catalog-management
[PM8]: https://docs.camerabits.com/support/solutions/articles/48001162818-offline-or-missing-media
[CB1]: https://forums.camerabits.com/index.php?topic=14953.0
[CB2]: https://forums.camerabits.com/index.php?topic=16484.0
[CB3]: https://forums.camerabits.com/index.php?topic=17023.0
[CB4]: https://forums.camerabits.com/index.php?topic=12177.0
[CB5]: https://forums.camerabits.com/index.php?topic=13855.0
[CB6]: https://forums.camerabits.com/index.php?topic=14400.0
[CB7]: https://forums.camerabits.com/index.php?topic=16440.0
[CB8]: https://forums.camerabits.com/index.php?topic=15691.0
[DK1]: https://docs.digikam.org/en/main_window/image_view.html
[DK2]: https://docs.digikam.org/en/setup_application/database_settings.html
[DT1]: https://docs.darktable.org/usermanual/5.6/en/special-topics/variables/
[DT2]: https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/lighttable/import/
[DT3]: https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/shared/export/
[DT4]: https://docs.darktable.org/lua/stable/lua.scripts.manual/scripts/contrib/rename_images/
[DT5]: https://discuss.pixls.us/t/slow-image-import-to-a-large-library/22327
[DT6]: https://github.com/darktable-org/darktable/issues/13569
[DT7]: https://discuss.pixls.us/t/solved-opening-db-from-lan-why-read-only/47238
[DT8]: https://docs.darktable.org/usermanual/5.6/en/overview/sidecar-files/local-copies/
[AP1]: https://developer.apple.com/documentation/vision/classifyimagerequest
[AP2]: https://developer.apple.com/documentation/vision/classificationobservation
[AP3]: https://developer.apple.com/documentation/vision/generateimagefeatureprintrequest
[AP4]: https://developer.apple.com/documentation/vision/calculateimageaestheticsscoresrequest
[AP5]: https://developer.apple.com/documentation/vision/detectfacecapturequalityrequest
[AP6]: https://developer.apple.com/videos/play/wwdc2019/222/
[AP7]: https://developer.apple.com/documentation/vision/recognizetextrequest
[AP8]: https://developer.apple.com/documentation/vision/recognizedocumentsrequest
[AP9]: https://developer.apple.com/documentation/vision/detectlenssmudgerequest
[AP10]: https://developer.apple.com/documentation/foundationmodels
[AP11]: https://developer.apple.com/documentation/updates/foundationmodels
[AP12]: https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation
[AP13]: https://developer.apple.com/documentation/foundationmodels/managing-the-context-window
[AP14]: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum
[AP15]: https://www.apple.com/apple-intelligence/
[AP16]: https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest
[AP17]: https://developer.apple.com/documentation/corelocation/clgeocoder
[AP18]: https://developer.apple.com/documentation/mapkit/mkclusterannotation
[AP19]: https://developer.apple.com/documentation/imageio/cgimagemetadatacreatexmpdata(_:_:)
[AP20]: https://developer.apple.com/documentation/imageio/cgimagedestinationcopyimagesource(_:_:_:_:)
[AP21]: https://developer.apple.com/documentation/coreservices/file_system_events
[AP22]: https://developer.apple.com/documentation/coreservices/1444453-fseventscopyuuidfordevice
[AP23]: https://developer.apple.com/documentation/coreservices/kfseventstreameventflagmount
[AP24]: https://developer.apple.com/documentation/coreservices/kfseventstreameventextendedfileidkey
[AP25]: https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/FileSystemEventSecurity/FileSystemEventSecurity.html
[AP26]: #sources
[AP27]: #sources
[AP28]: https://support.apple.com/en-us/102064
[AP29]: https://support.apple.com/en-us/101442
[AP30]: https://support.apple.com/en-us/108345
[AP31]: https://developer.apple.com/documentation/vision/faceobservation
