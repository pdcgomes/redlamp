# Library and catalog baseline: Lightroom Classic and Lightroom

How Lightroom Classic's Library module and catalog work as of **Lightroom Classic 15.6** (29 September 2026), with a short look at the cloud-based Lightroom (Desktop 9.6, released the same day) ([Q3]), and what their users complain about. Written for Redlamp's library and catalog work. All sources were checked on **2026-10-05**. **Evidence** is what a source says; **Assessment** is our reading of it.

**Access notes.** Adobe's help site returned HTTP 403, so Adobe's own statements come from its staff posts on Adobe Community. The Lightroom Queen (Victoria Bampton's site) is a secondary source for release detail; forum posts are users' reports. Counts were read on 5 October 2026. Refusals are under [Not reached](#not-reached).

---

## Summary

- **One SQLite database holds the library.** The `.lrcat` file keeps records, edits and groupings; previews, smart previews and AI pixel data sit in stores beside it ([Q20], [Q15], [Q2]).
- **The catalog doesn't watch the disk.** Files moved or renamed in Finder go missing and Synchronize Folder can't relink them; with import problems, missing photos are the largest topic of forum complaints (§10) ([Q18], [Q19]).
- **XMP is a partial copy.** Flags joined it in 13.2 (February 2024) and label colours in 15.0 (October 2025); collections, stacks, virtual copies and history stay in the catalog ([Q13], [Q4], [FR3]).
- **No network catalogs.** Photos may sit on a NAS but the catalog may not; the request, open since May 2011, has 570 replies, the most of any ([Q22], [FR1]).
- **Size isn't the stated limit, but users slow down from about 300,000 photos.** Adobe's Rikk Flohr would worry at 10 million and one user's catalog of over 996,000 photos opens in under 10 s, yet others report sluggish grids and minutes-long edits at 338,000 to 540,000 ([F1], [F3], [BR1]).
- **Previews and AI data take the disk.** Users report 315 GB of previews in one catalog folder and 464 GB of AI data for 16,000 photos ([F4]).
- **Smart collections have gaps.** They don't sync or show stacks, and their live counts slow metadata entry in large catalogs ([FR5], [FR8], [Q27]).
- **Stacks are tied to folders,** and auto-stack by capture time ignores exposure length; both requests date from 2011 ([FR6], [FR7]).
- **Assisted Culling reached general availability in 15.4 (June 2026).** It scores subject and eye focus, open eyes (per face since 15.4), exposure, documents and misfires, in Import and Library ([AD2], [Q1]).
- **Duplicate detection (15.4) finds exact matches** and shows them as stacks; its first build could delete unrejected photos and was withdrawn for two days ([AD1], [Q1]).
- **Custom colour labels are in Lightroom Desktop 9.4, not Classic 15.4,** contrary to the brief; Classic keeps five, stored as text ([Q1], [Q36]).
- **Keys without customisation.** The single-key vocabulary is rich, but there's no shortcut editor, and a user reports that 15.0 renumbered panel shortcuts ([Q45], [FR4], [Q4]).

---

## 1. Catalog and storage

**Evidence.** The catalog is an SQLite database of text records holding each photo's location, metadata and Develop settings; the photos stay in folders on disk ([Q16], [Q20]).

| File or folder beside the catalog | Holds | Source |
|---|---|---|
| `Name.lrcat` | the catalog database | [Q15], [Q20] |
| `.lrcat-wal`, `.lrcat-shm` | data not yet written into the catalog | [Q15] |
| `.lrcat-data` | pixel data: AI masks, Generative Remove fills, Denoise and Super Resolution results (Classic 11.0 on) | [Q2], [Q15] |
| `Previews.lrdata` | Library previews at several sizes | [Q15], [Q24] |
| `Smart Previews.lrdata` | 2,560-pixel partly processed raw data for editing without the originals | [Q24] |
| `Helper.lrdata`, `Sync.lrdata` | performance cache; local cache of cloud sync | [Q4], [Q15] |
| `Backups/` | dated folders, each with a zipped catalog | [Q21], [Q43] |

- **Previews.** Standard previews default to about the screen's width; 1:1 previews are full-resolution Adobe RGB JPEGs, discarded after a day, a week or 30 days if chosen; import can use the camera's embedded JPEG instead ([Q24]). 14.0 (October 2024) added a preview cache size limit, 14.1 a command to discard standard and 1:1 previews, and 14.5 (August 2025) GPU preview building ([Q10], [Q11], [Q9]).
- **Missing photos.** A missing photo gets a thumbnail badge (once a question mark); a missing folder turns grey with a question-mark icon, an offline volume grey ([Q18]). Find Missing Folder on the highest missing parent relinks its subfolders, but each file renamed outside Lightroom is relinked by hand; since 14.4 (June 2025), when a whole folder is missing, a photo's badge offers to locate the folder ([Q18], [Q8]).
- **Synchronize Folder** imports files other apps added and can rescan metadata; its option to remove missing photos deletes their edits, and it never relinks ([Q19]). Users report it flagging present photos as missing ([BR6]).
- **Network and several Macs.** Classic isn't built for network or multi-user use; photos may sit on a NAS, the catalog may not, and workarounds such as a network disk image can corrupt it ([Q22], [Q23]). In 2011 an Adobe employee's answer was an external drive holding both catalog and photos ([FR1]).
- **Corruption and backups.** Corruption usually follows a crash, a power cut or a drive dropping out mid-write; Lightroom offers a repair, else a backup is restored by hand ([Q20], [Q21]). Backups run on quitting (weekly by default), are zipped, hold only the catalog and are never pruned ([Q42], [Q43], [Q17]). 14.2 added a Backups tab and 15.5 (August 2026) a startup check of `.lrcat-data` ([Q12], [Q2]). 14.0, 15.0 and 15.4 each upgraded the catalog format and kept the old catalog aside, so going back means restoring it ([Q10], [Q4], [Q1], [AD1]).
- **macOS permissions.** Adobe's community team asks Mac users to grant Full Disk Access; without it, it says, imports and metadata writes misbehave and photos can appear missing ([AD3]).

**The cloud-based Lightroom** organises albums, grouped in folders, and searches them with Adobe's cloud image analysis ([Q50], [Q49]). Desktop's Local mode (October 2023) browses disk folders with edits in XMP and no catalog ([Q39], [Q40]). Desktop later gained smart albums (8.0, October 2024), a secondary window (8.2, February 2025), subfolder browsing, batch rename and colour labels (9.0, October 2025), natural-language search in cloud mode (9.3) and ten named colour labels (9.4, June 2026) ([Q10], [Q12], [Q4], [Q7], [Q1]). Classic syncs only chosen collections, as smart previews, and keywords only since 15.4 ([Q41], [Q37], [FR2]).

**Assessment.** The catalog is the only complete record and the disk a set of pointers into it; missing photos, the network ban and corruption follow from that. Sidecars beside each photo remove the pointer problem, but Redlamp still has to notice moves quickly.

## 2. Browsing and culling

| View | Key (Mac) | Notes |
|---|---|---|
| Grid | G | J cycles cell styles |
| Loupe | E | Z or Space zooms |
| Compare | C | a Select and a Candidate; arrow keys promote the next photos |
| Survey | N | several photos side by side, dropping weaker ones |
| People | O | named and unnamed faces |
| Secondary display | Cmd+F11 | Shift+G, E, C or N picks its view; Loupe can be normal, live or locked |

Sources: [Q45], [S2], [Q48].

- **Marking.** P, X and U set flags, 0 to 5 ratings, 6 to 9 red to blue labels (purple has no key). Holding Shift, or turning on Caps Lock, moves to the next photo after marking ([Q45], [Q36]).
- **Quick Collection and target.** B adds to the Quick Collection or to whichever collection is set as target ([Q45], [Q35]). The Painter sprays labels, ratings, flags, keywords, metadata or Develop presets, rotation or target membership across thumbnails, and Option erases ([Q35]).
- **Stacks.** Cmd+G stacks and S collapses ([Q45]). Stacks can't span folders and don't show in smart collections; auto-stack splits on the gap between capture times, which breaks long-exposure brackets ([FR6], [FR8], [FR7]).
- **Order and memory.** Collections and folders take a custom order, which bug threads report lost after an accidental drag and capped at 52 moves ([BR16], [BR19]). Since 14.4 a preference remembers the selection in each of the 25 latest sources ([Q8]).
- The filmstrip follows the current source in every module (unverified).

## 3. Search and smart collections

- **Filter bar** (\\): Text, Attribute and Metadata; Cmd+L toggles all filters; text takes `+` for starts-with or ends-with and `!` to exclude ([Q45]). Metadata columns are facets, four by default, combined with AND (per a forum user), and filter sets save as presets ([F6], [Q39]).
- **Smart collections** are rows of rules, with nested groups added by Option-clicking + ([Q29]). Criteria grow with releases: masking and AI edits (13.2), Denoise and Super Resolution (14.4), likes and comments from web viewers (15.0), AI-edit filters (15.4); 15.0 also added stacking to the Attribute filter ([Q13], [Q8], [Q4], [AD1]).
- **Collections** gather photos from any folders and keep their own order; collection sets hold collections, not photos. Neither is written to the files, so the Lightroom Queen prefers keywords for lasting groupings ([Q30]); cloud album folders don't become collection sets ([Q41]).
- **Limits.** Smart collections don't sync (Adobe: Not Prioritized) or show stacks ([FR5], [FR8]). Their live counts slow metadata entry on large catalogs; the advice is to close the Collections panel ([Q27], [Q26]). Users ask for a missing-photo rule ([FR9]).
- **No content search.** Classic has no AI search; the cloud apps do ([Q39], [Q49]). Requests for automatic tagging and similar-photo search are open ([FR10], [FR11]).
- **Sort.** Classic has 21 sort orders, the cloud apps 6 (July 2025); users want multi-field sorting ([Q39], [FR12]).

## 4. Keywords and metadata

- **Keyword List.** Keywords nest by dragging, and each carries four options: Include on Export, Export Containing Keywords, Export Synonyms and Person ([Q32], [BR21]). Synonyms are searchable; the cloud apps have none ([Q51]).
- **Entry.** The Keywording panel suggests as you type; keyword sets hold nine, applied with Option and 1 to 9; Cmd+K jumps to the field ([Q34], [Q45]).
- **On write,** hierarchical keywords go out flat and as a hierarchy, with parents added automatically; parents marked not to export return as top-level keywords after a round trip ([Q33]).
- **Export Keywords** writes tab-indented text keeping only Include on Export, or since 12.2 (February 2023) a CSV with every option ([Q31], [BR21]). Imports must be UTF-8, the CSV lacks a byte-order mark, and a keyword with a comma breaks import ([F7], [F8]). The text file reportedly brackets non-exported keywords and puts synonyms in braces (unverified).
- **Maintenance.** Merging duplicate keywords is manual, and Windows lists stop at about 1,600 rows ([Q32], [BR5], [F2]).
- **Colour labels** are text mapped to five colours by a label set, and unmatched text shows white ([Q36]); 15.0 also writes `xmp:LabelColor` ([Q4]).
- **Metadata presets** apply at import and through the Painter ([Q35], [Q8]).
- **Faces.** Since Lightroom 6 (April 2015) Classic indexes the catalog or the current source; People view stacks likely matches, and names become person keywords ([Q48]). Users ask to choose a person's thumbnail ([FR14]).
- **Map.** The Map module uses Google Maps, reads GPS tracklogs and looks up addresses in the background ([BR12], [BR13], [Q45], [Q27], [Q1]). Bugs recur with grey or offline maps and misplaced pins ([BR23], [BR14]); users ask for OpenStreetMap and tracklogs over 50,000 points ([FR16], [FR17]).

## 5. Import and renaming

- **Modes:** Copy, Move, Add (in place) and Copy as DNG ([Q17], [Q8]).
- **File handling:** previews (Minimal, Embedded & Sidecar, Standard or 1:1) and smart previews; Don't Import Suspected Duplicates; a second copy elsewhere; add to a collection ([Q24], [Q38], [Q17], [Q39]). Since 14.4 duplicates match on capture time and file size, whatever the name ([Q8]).
- **Renaming, settings and destination:** file-name templates, metadata presets and per-camera defaults apply on import; the dialog sorts and filters its view; destination folders can follow capture dates ([Q39], [Q8], [F2]).
- 15.1 (December 2025) improved the Import dialog's embedded previews ([Q5]). 15.0 put Assisted Culling in the dialog; the Lightroom Queen warns that a card could then be formatted before its rejects were imported ([Q4]).
- Second copies are hard to restore from, and users want a raw-only import and to erase the card afterwards ([Q17], [FR18], [FR19]).

## 6. XMP and interop

| Data | In XMP? | Source |
|---|---|---|
| Develop settings, as their current state | Yes | [Q25], [Q40] |
| Ratings, label text, keywords (flat and hierarchical) | Yes | [Q33], [Q36], [FR3] |
| Flags | Since 13.2 (February 2024); Bridge ignores them | [Q13] |
| Label colour | Since 15.0, as `xmp:LabelColor` | [Q4] |
| Large pixel edits (AI masks, Denoise) | Since 15.0, in `.acr` sidecars for proprietary raws | [Q4] |
| Collections, stacks, virtual copies | No | [Q30], [FR3], [Q25] |
| History steps | No, per a reader's reply | [Q25] |
| Develop panel on/off switches | No (2017) | [Q25] |
| Face regions | Reported yes (unverified) | [Q48] |

- **Automatically write changes into XMP** (Catalog Settings › Metadata) costs speed on slow drives ([Q25]). 14.4 paused writes during import and saves Develop changes every 10 s; users still report constant "saving XMP" slowdowns ([Q8], [BR4]).
- **Sidecar or embedded.** Proprietary raws get an `.xmp` sidecar; DNG, JPEG and TIFF carry XMP inside the file, so backup software copies the whole file again after each change ([Q44], [Q40], [FR20]).
- **Growth.** In 14.4, enhancing without a DNG wrote very large XMP into sidecars, and the same data was duplicated in the catalog ([Q8], [Q4]). One user's catalog grew from 8 to 14 GB in a month at 240,000 photos, which forum regulars tied to XMP writing ([F5]).

## 7. Module switching and keys

- **Modules.** G, E, C and N open Library views and D opens Develop; Cmd+Option+1 to 7 open Library, Develop, Map, Book, Slideshow, Print and Web; Cmd+Option+Up returns to the previous module ([Q45]).
- **Panels.** Cmd+0 to 9 toggle right-hand panels, Tab hides the side panels, Shift+Tab hides everything, and F5 to F8 hide single edges, F6 being the filmstrip ([Q45]).
- **No editor.** Users remap menu commands in macOS settings, edit a TranslatedStrings file or buy the Any Shortcut plug-in; G and D are hard-coded ([Q46], [Q47]). A user complains that 15.0's culling panels, added at the top, renumbered the panel shortcuts ([Q4]).

## 8. Scale and performance

| Report (date, version) | Photos | Data sizes | Behaviour | Source |
|---|---|---|---|---|
| Adobe staff member (Mar 2025) | many catalogs in the millions | — | would start to worry at 10 million | [F1], [AD4] |
| Sports photographer (Apr 2024) | over 996,000 | — | opens in under 10 s | [F3] |
| Windows workstation (Sep 2024, 13.5.1) | 540,000 | 6.06 GB catalog; 8 TB of previews and cache | choppy grid, slow labels and keywords, preview rebuild of 3 to 4 weeks | [BR1] |
| Reply (Jun 2025) | about 500,000 | — | 16 h import, under 30 min in a new catalog | [BR1] |
| Forum (Mar 2025) | 338,000 | 5 GB catalog | with sync on, ratings and collection adds take 20 to 30 minutes | [F1] |
| Forum (May 2026) | 117,000; 16,000 | 5.5 GB catalog and 6.5 GB `.lrcat-data`; 464 GB `.lrcat-data`; elsewhere 315 GB of previews | AI data and previews outgrow the catalog | [F4] |

- **Advice** (the Lightroom Queen, 2021): catalog and previews on an SSD; Optimize Catalog after big changes; screen-sized previews built overnight; a 5 to 10 GB Camera Raw cache; smart previews for Develop; XMP auto-write off; pause face detection, address lookup and sync ([Q24] to [Q28]). It calls 1 million photos big and 50,000 small ([Q26]). Forum users add excluding the catalog from antivirus and indexing ([F1]).

**Assessment.** The reports point to work that grows with catalog size in everyday actions (sync bookkeeping, collection membership, smart-collection counts, preview queues), not to a database limit.

## 9. AI features

| Release | Assisted Culling | Source |
|---|---|---|
| 15.0 (28 Oct 2025) | early access, Classic and Desktop: selects and rejects by subject focus, eye focus and open eyes; batch actions; in Import too; stacks by visual similarity, best photo on top | [Q4], [AD2] |
| 15.2 (20 Feb 2026) | group portraits, weddings and events | [Q6], [AD2] |
| 15.3 (15 Apr 2026) | shallow depth of field kept; rejects retrained: exposure (with a slider), documents, misfires | [Q7], [AD2] |
| 15.4 (18 Jun 2026) | general availability; Eye Focus and Eyes Open scores per face | [AD1], [Q1] |

- **Adobe:** each criterion can be switched off, three have sensitivity sliders, and it costs nothing extra ([AD2]); automatic analysis can be disabled in Catalog Settings ([S3]). Whether it runs on the Mac isn't stated (unverified).
- **Users:** the analyse-all setting switches itself back on, sharp frames get rejected, re-analysing 71,031 photos crashed Lightroom, and landscape brackets go unrecognised ([AD2], [Q1], [Q4]).
- **Duplicates (15.4):** a pausable background index, hours long on first run, feeds a Duplicates view of exact matches as collapsed stacks ([AD1], [Q1]). Delete Rejected Photos there deleted every photo shown; 15.4 was withdrawn on 20 June and 15.4.1 shipped on 22 June ([Q1], [BR17]). Before that, users relied on plug-ins ([Q38]).
- **An activity indicator (15.4)** shows when culling, XMP saving, address lookup, duplicate or face detection run ([Q1]).

**Assessment.** Adobe's library AI centres on culling people shots; content search stays in the cloud apps.

## 10. Recurring complaints, ranked

**Method.** We read every listing page of Adobe Community's Classic Feature Requests and Bug Reports boards (1,550 and 1,450 distinct titles of the 1,827 and 1,702 reported, back to 2011) and the 3,750 most recently active threads of the Lightroom Queen forum's Classic board (since about March 2024), keeping the 1,069 forum titles with problem words such as "not", "error", "slow" or "missing". Keyword patterns assigned titles to topics, some to several. It is a rough frequency measure; DPReview and Reddit could not be read.

| Rank | Complaint | Titles: requests / bugs / forum | Examples |
|---|---|---|---|
| 1 | Import is slow or fails, or lacks options (raw only, erase card) | 72 / 80 / 82 | [FR18], [FR19], [BR15], [F15] |
| 2 | Sync with the cloud apps is partial, slow or stuck | 40 / 67 / 73 | [FR5], [BR3], [BR20], [F16] |
| 3 | Finding photos: filters, search and sort fall short | 82 / 57 / 21 | [FR12], [FR10], [FR11] |
| 4 | Folders: display limits, parents, renames | 57 / 41 / 59 | [BR5], [F2], [FR21], [BR7] |
| 5 | Previews: disk use, stale or poor previews | 42 / 70 / 34 | [FR22], [BR18], [QA5], [F4] |
| 6 | Collections and smart collections | 73 / 40 / 28 | [FR5], [FR8], [BR16], [BR19] |
| 7 | Keyboard shortcuts: no editor, regressions | 55 / 73 / 3 | [FR4], [BR22], [Q4] |
| 8 | Keyword management | 42 / 46 / 24 | [FR13], [FR24], [FR25], [F8] |
| 9 | Missing photos and relinking | 9 / 14 / 83 | [Q18], [F9], [F10], [BR6], [FR26], [FR27] |
| 10 | Catalog corruption, failure to open, backups | 14 / 17 / 48 | [BR8], [BR9], [F12], [BR10], [BR11] |
| 11 | Face recognition | 50 / 17 / 7 | [FR14], [FR15] |
| 12 | General slowness of Library work | 1 / 34 / 35 | [BR2], [BR1], [F11], [QA1] |
| 13 | Map module and GPS | 11 / 44 / 3 | [BR12], [BR23], [BR14], [FR16] |
| 14 | XMP behaviour | 9 / 26 / 16 | [BR4], [FR3], [FR20], [F5] |
| 15 | Stacks | 22 / 11 / 8 | [FR6], [FR7], [FR8] |
| 16 | Duplicates | 11 / 11 / 11 | [QA2], [FR28], [BR17] |
| 17 | Network catalogs and several computers | 6 / 10 / 8 | [FR1], [FR29], [FR30], [QA3], [QA4], [F13], [F14] |

By readers the order changes: the most-viewed threads are about speed ([QA1], 633,347 views; [BR2], 109,325), the most-replied request is the network catalog ([FR1], 570 replies), and a duplicates question has 142,828 views ([QA2]). Titles undercount slowness, which users describe in many ways.

## 11. Recommendations for Redlamp

| # | Recommendation | Verdict | Reason |
|---|---|---|---|
| 1 | Keep Classic's single keys: G, E, C, N, D, P, X, U, 0 to 5, 6 to 9, B, with Shift or Caps Lock to advance | Adopt | Switchers bring years of muscle memory ([Q45]). |
| 2 | One command list drives menus, the palette and remappable keys; keys never move when panels change | Do better | Classic has no shortcut editor, and 15.0 shifted panel keys ([FR4], [Q4]). |
| 3 | Put what Classic keeps only in its catalog into the `.redlamp` sidecar: flags, collections, stacks, virtual copies, history, label colour | Do better | Makes the index disposable; the XMP request is open since 2011 ([FR3]). |
| 4 | Detect moves and renames (file events, file identity, content hash) and relink automatically, whole trees at once; "missing" as a filter and a rule | Build | Classic relinks by hand, a renamed file at a time ([Q18], [FR26], [FR27], [FR9]). |
| 5 | Rescans list additions, moves and losses for review and never drop a missing photo's record by default | Do better | Synchronize Folder's remove option discards work ([Q19]). |
| 6 | Photo folders on SMB and NFS with polled change detection and the index on the Mac; several Macs share folders through sidecars, merged field by field | Build | Classic bars network catalogs, the most-replied request ([FR1], [Q22]). |
| 7 | Preview tiers (thumbnail, screen, 1:1) with a disk budget, embedded JPEGs first | Adopt | Proven; 14.0's cap answers the disk complaints ([Q24], [Q10]). |
| 8 | Build previews ahead for unseen photos, refresh stale ones, and budget AI pixel data | Do better | Requests and bugs on stale previews and runaway AI data ([FR22], [BR18], [FR23], [F4]). |
| 9 | Nested any/all rule trees for smart collections, facet columns, saved filter presets | Adopt | Classic's strongest finding tools ([Q29], [F6]). |
| 10 | Evaluate smart collections incrementally so counts never stall typing at 1,000,000 photos; show stacks; save the current filter as one | Do better | Counting slows metadata entry in large catalogs ([Q27], [FR8]). |
| 11 | Stacks across folders, shown in every view; auto-stack on capture time plus exposure time, and on visual similarity | Do better | Both 2011 requests are still open ([FR6], [FR7]). |
| 12 | Keyword hierarchy with synonyms, export options and person type, plus one-step merge, virtualised lists and a documented UTF-8 file that keeps every option | Do better | Merging is manual, lists stop near 1,600 rows on Windows, exports drop options ([Q32], [BR5], [BR21], [F8]). |
| 13 | Named colour labels beyond five, with the colour stored with the photo; write `xmp:Label` and `xmp:LabelColor` on export | Do better | Classic stores text only; Desktop added custom labels in 2026 ([Q36], [Q4], [Q1]). |
| 14 | Duplicate detection by content hash in the background, with deletion only from an explicit, confirmed list | Do better | 15.4's Duplicates view deleted unrejected photos ([Q1], [BR17]). |
| 15 | Copy, move and add; rename and destination templates; a verified second copy; duplicate checks on capture time and size; a raw-only switch | Adopt | Familiar, and the additions are open requests ([Q8], [FR18], [FR19]). |
| 16 | Culling scores computed on the Mac, shown as filters with user thresholds, opt-in per folder, never rejecting by themselves | Do better | Users report the analyse-all setting reverting and sharp frames rejected ([AD2]). |
| 17 | Faces and places with Apple's Vision and MapKit: editable person thumbnails, per-folder re-index, GPX without a point limit | Do better | The Google-based map breaks, and face requests are open ([BR12], [BR13], [FR14], [FR17]). |
| 18 | Embed metadata inside DNG, JPEG or TIFF by default | Skip | It makes backups copy whole files again ([Q44], [FR20]). |
| 19 | Multiple catalogs, merging and catalog-format upgrades | Skip | A folder-based library rebuilds its index and has nothing to merge ([Q4], [FR30]). |
| 20 | Test 1,000,000-photo libraries on SSD, spinning disk and SMB against budgets for launch, scrolling, rating, collecting and import | Build | Classic users report slowdowns from about 300,000 photos ([F1], [BR1]). |

---

## Sources

All checked 2026-10-05; dates are publication (and update) dates.

**Adobe, staff posts on Adobe Community**

- AD1: Lightroom Classic v15.4 is Live! (Anshul Saini, Community Manager), 18 Jun 2026. https://community.adobe.com/announcements-673/lightroom-classic-v15-4-is-live-cull-people-shots-faster-auto-detect-duplicates-sync-keywords-everywhere-1627070
- AD2: (Early Access) Assisted Culling (LrClassic), posted by Rikk Flohr, written by Kwamina Arthur, Lightroom product manager; 24 Sep 2025, closed 16 Jun 2026; 141 replies, 165,136 views. https://community.adobe.com/questions-675/early-access-assisted-culling-lrclassic-983825
- AD3: Quick Tips: How to give Full Disk Access to Lightroom Classic on macOS (Sameer K, Community Manager), 10 Jan 2022. https://community.adobe.com/questions-675/quick-tips-how-to-give-full-disk-access-to-lightroom-classic-on-macos-961364
- AD4: Rikk Flohr's profile: worked on Adobe's photography products 2011 to 2026, retired 18 Sep 2026. https://community.adobe.com/members/rikk-flohr-retired-1348193

**Adobe Community, feature requests** (votes / replies / views on 5 Oct 2026; board: https://community.adobe.com/feature-requests-676)

- FR1: Allow Catalog to be stored on a networked drive (May 2011, open; 35 / 570 / 14,408). https://community.adobe.com/feature-requests-676/p-allow-catalog-to-be-stored-on-a-networked-drive-666362
- FR2: Ability to sync Lightroom Classic keywords with the Lightroom Ecosystem (released Jun 2026; 46 / 375 / 17,787). https://community.adobe.com/feature-requests-676/p-ability-to-sync-lightroom-classic-keywords-with-the-lightroom-ecosystem-666425
- FR3: Include additional metadata in XMP (flags, collections, VCs) (May 2011, open; 0 / 118 / 2,690). https://community.adobe.com/feature-requests-676/p-include-additional-metadata-in-xmp-flags-collections-vc-s-etc-664991
- FR4: Allow for keyboard shortcut customization (open; 83 / 277 / 16,470). https://community.adobe.com/feature-requests-676/p-allow-for-keyboard-shortcut-customization-666358
- FR5: Ability to sync Smart Collections with Ecosystem Clients (not prioritized; 21 / 309 / 10,315). https://community.adobe.com/feature-requests-676/p-ability-to-sync-smart-collections-with-ecosystem-clients-665344
- FR6: Stacking in folders and collections should be global (Apr 2011, open; 8 / 88 / 3,886). https://community.adobe.com/feature-requests-676/p-stacking-in-folders-and-collections-should-be-global-666404
- FR7: Better auto stacking for bracketing, HDR, focus stacking and panoramas (Apr 2011, open; 28 / 65 / 6,130). https://community.adobe.com/feature-requests-676/p-better-auto-stacking-for-bracketing-hdr-focus-stacking-and-panoramas-666365
- FR8: Show stack in Smart collections (open). https://community.adobe.com/feature-requests-676/p-show-stack-in-smart-collections-665317
- FR9: Add 'Missing Photo' status to Grid Filter Bar and Smart Collections (open). https://community.adobe.com/feature-requests-676/p-add-missing-photo-status-to-grid-filter-bar-and-smart-collections-665142
- FR10: Automatic image tagging (open; 27 / 40 / 6,341). https://community.adobe.com/feature-requests-676/p-automatic-image-tagging-664740
- FR11: Allow us to search for similar photos in Lightroom Classic (open). https://community.adobe.com/feature-requests-676/p-allow-us-to-search-for-similar-photos-in-lightroom-classic-665403
- FR12: Sort by more fields, sort by multiple fields (open; 26 / 47 / 4,990). https://community.adobe.com/feature-requests-676/p-sort-by-more-fields-sort-by-multiple-fields-664750
- FR13: Better keyword management (open; 9 / 149 / 6,225). https://community.adobe.com/feature-requests-676/p-better-keyword-management-666408
- FR14: Allow Named People thumbnail photo to be changed (open; 36 / 30 / 4,055). https://community.adobe.com/feature-requests-676/p-allow-named-people-thumbnail-photo-to-be-changed-664847
- FR15: Allow facial recognition feature to re-index a folder/collection (released; 110 replies). https://community.adobe.com/feature-requests-676/p-allow-facial-recognition-feature-to-re-index-a-folder-collection-664812
- FR16: OpenStreetMap (OSM) as Map Style in Map Module (open). https://community.adobe.com/feature-requests-676/p-openstreetmap-osm-as-map-style-in-map-module-665662
- FR17: GPS track limited to 50.000 points (open). https://community.adobe.com/feature-requests-676/p-gps-track-limited-to-50-000-points-665226
- FR18: Add option to import RAW only (open; 54 / 10 / 11,794). https://community.adobe.com/feature-requests-676/p-add-option-to-import-raw-only-665061
- FR19: Delete Images on Card after Import (not prioritized; 6 / 113 / 5,926). https://community.adobe.com/feature-requests-676/p-delete-images-on-card-after-import-666337
- FR20: Store the xmp metadata outside DNG, jpeg etc file to be backup efficient (open; 34 / 52 / 5,872). https://community.adobe.com/feature-requests-676/p-store-the-xmp-metadata-outside-dng-jpeg-etc-file-to-be-backup-efficient-665133
- FR21: Show Parent Folders by Default (open; 4,236 views). https://community.adobe.com/feature-requests-676/p-show-parent-folders-by-default-665056
- FR22: Build Library Previews in the background regardless of their having been visible (open). https://community.adobe.com/feature-requests-676/p-build-library-previews-in-the-background-regardless-of-their-having-been-visible-666071
- FR23: AI blob storage size should be limited and automatically cleaned up (open). https://community.adobe.com/feature-requests-676/p-ai-blob-storage-size-should-be-limited-and-automatically-cleaned-up-like-previews-666187
- FR24: Merge duplicate keywords in Lightroom list (open). https://community.adobe.com/feature-requests-676/p-merge-duplicate-keywords-in-lightroom-list-665316
- FR25: Better Support for Keyword Synonyms (open). https://community.adobe.com/feature-requests-676/p-better-support-for-keyword-synonyms-664870
- FR26: Auto locate moved files in library (open). https://community.adobe.com/feature-requests-676/p-auto-locate-moved-files-in-library-664899
- FR27: Relink multiple folders at a time (open). https://community.adobe.com/feature-requests-676/p-relink-multiple-folders-at-a-time-666127
- FR28: Built-In Duplicate Finder (open). https://community.adobe.com/feature-requests-676/p-built-in-duplicate-finder-666195
- FR29: I would like to synchronize over LAN/Cable instead of internet (open; 126 replies). https://community.adobe.com/feature-requests-676/p-i-would-like-to-synchronize-over-lan-cable-instead-of-internet-665276
- FR30: Multiple catalog syncing (open; 77 replies). https://community.adobe.com/feature-requests-676/p-multiple-catalog-syncing-665134

**Adobe Community, bug reports** (replies / views on 5 Oct 2026; board: https://community.adobe.com/bug-reports-674)

- BR1: Performance Slow on Large Catalog (540k images) (19 Sep 2024; 43 / 8,835). https://community.adobe.com/bug-reports-674/p-performance-slow-on-large-catalog-540k-images-crash-9690382-664319
- BR2: LrC 12.2.1 fails to start/launch or is extremely slow launching (211 / 109,325). https://community.adobe.com/bug-reports-674/p-lrc-12-2-1-fails-to-start-launch-or-is-extremely-slow-launching-664007
- BR3: Adding to/Creation of a new Target collection takes minutes unless Sync is paused (28 / 23,142). https://community.adobe.com/bug-reports-674/p-adding-to-creation-of-a-new-target-collection-takes-minutes-unless-sync-is-paused-664315
- BR4: Constantly "saving xmp for xx photos" slowing down my Lightroom Classic (23 / 12,774). https://community.adobe.com/bug-reports-674/p-constantly-saving-xmp-for-xx-photos-slowing-down-my-lightroom-classic-664312
- BR5: (Windows) Panel is limited to 1600 items (folders, keywords, etc) (33 / 15,522). https://community.adobe.com/bug-reports-674/p-windows-panel-is-limited-to-1600-items-folders-keywords-etc-663697
- BR6: Synchronize Folder incorrectly shows photos as missing (15 / 6,991). https://community.adobe.com/bug-reports-674/p-synchronize-folder-incorrectly-shows-photos-as-missing-664142
- BR7: loses connection with files after folder is renamed (137 / 7,843). https://community.adobe.com/bug-reports-674/p-loses-connection-with-files-after-folder-is-renamed-662986
- BR8: "The catalog could not be opened due to an unexpected error" (113 / 7,463). https://community.adobe.com/bug-reports-674/p-message-the-catalog-could-not-be-opened-due-to-an-unexpected-error-662989
- BR9: After the new version update, "Unexpected error opening catalog" (137 / 5,697). https://community.adobe.com/bug-reports-674/p-after-the-new-version-update-today-unexpected-error-opening-catalog-663037
- BR10: "lrcat-data" folder missing from Backup Zip files (3,871 views). https://community.adobe.com/bug-reports-674/p-lrcat-data-folder-missing-from-backup-zip-files-663924
- BR11: LrC 15.4 & 15.4.1 cannot create catalog backups directly on SMB NAS shares (Sep 2026). https://community.adobe.com/bug-reports-674/p-lrc-15-4-15-4-1-cannot-create-catalog-backups-directly-on-smb-nas-shares-backup-fails-during-compression-1628839
- BR12: Map module will not load Google Maps (5,085 views). https://community.adobe.com/bug-reports-674/p-map-module-will-not-load-google-maps-664049
- BR13: Map appears all grey with high-latency network connections to Google's servers. https://community.adobe.com/bug-reports-674/p-map-appears-all-grey-with-high-latency-network-connections-to-google-s-servers-664429
- BR14: Photo placed in wrong spot on map (72 / 9,306; Aug 2026). https://community.adobe.com/bug-reports-674/p-photo-placed-in-wrong-spot-on-map-664029
- BR15: Import is creating OS-level duplicate files named (-2) (169 / 12,551). https://community.adobe.com/bug-reports-674/p-import-is-creating-os-level-duplicate-files-named-2-when-using-devices-rather-than-files-663993
- BR16: Custom Order lost with slight accidental movement of thumbnail in filmstrip (171 / 3,446). https://community.adobe.com/bug-reports-674/p-custom-order-lost-with-slight-accidental-movement-of-thumbnail-in-filmstrip-663881
- BR17: Delete Rejected Photos in Duplicates view deletes all copies (Jun 2026). https://community.adobe.com/bug-reports-674/p-delete-rejected-photos-in-duplicates-view-deletes-all-copies-1628661
- BR18: Library Previews not updating (76 / 26,973). https://community.adobe.com/bug-reports-674/p-library-previews-not-updating-663816
- BR19: Limit of 52 reorderings in custom-ordered collections and folders (89 / 5,371). https://community.adobe.com/bug-reports-674/p-limit-of-52-reorderings-in-custom-ordered-collections-and-folders-663977
- BR20: Lightroom Classic no longer syncs completely, successfully (83 / 36,687). https://community.adobe.com/bug-reports-674/p-lightroom-classic-no-longer-syncs-completely-successfully-663016
- BR21: Import Keyword synonyms problem (Apr 2017; confirmed as a bug by Rikk Flohr). https://community.adobe.com/bug-reports-674/p-import-keyword-synonyms-problem-663895
- BR22: Unable to advance to the next photo (326 / 56,364). https://community.adobe.com/bug-reports-674/p-unable-to-advance-to-the-next-photo-664118
- BR23: Map module keeps flashing "map offline" when it's not (287 / 4,756). https://community.adobe.com/bug-reports-674/p-map-module-keeps-flashing-map-offline-when-it-s-not-663652

**Adobe Community, questions** (views on 5 Oct 2026; board: https://community.adobe.com/questions-675)

- QA1: Experiencing performance related issues in Lightroom 4.x (633,347). https://community.adobe.com/questions-675/experiencing-performance-related-issues-in-lightroom-4-x-987414
- QA2: How do I remove duplicates in my Lightroom Catalogue? (142,828). https://community.adobe.com/questions-675/how-do-i-remove-duplicates-in-my-lightroom-catalogue-952311
- QA3: Metadata Errors and Issues in LR Classic CC on NAS (128,747). https://community.adobe.com/questions-675/metadata-errors-and-issues-in-lr-classic-cc-on-nas-933002
- QA4: Lightroom & OneDrive, a match made in heaven? (110,094). https://community.adobe.com/questions-675/lightroom-onedrive-a-match-made-in-heaven-945384
- QA5: "Lightroom encountered an error when reading from its preview cache and needs to quit" (116,675). https://community.adobe.com/questions-675/lightroom-encountered-and-error-when-reading-from-its-preview-cache-and-needs-to-quit-938424

**The Lightroom Queen** (secondary source; release posts list Adobe's changes and fixed bugs)

- Q1: What's New in Lightroom Classic 15.4 (18 Jun 2026, updated 22 Jun 2026). https://www.lightroomqueen.com/whats-new-in-lightroom-2026-06/
- Q2: … 15.5 (3 Aug 2026, updated 29 Sep 2026). https://www.lightroomqueen.com/whats-new-in-lightroom-2026-08/
- Q3: … 15.6 (29 Sep 2026). https://www.lightroomqueen.com/whats-new-in-lightroom-2026-09/
- Q4: … 15.0 (28 Oct 2025, updated 10 Nov 2025), including reader comments. https://www.lightroomqueen.com/whats-new-in-lightroom-2025-10/
- Q5: … 15.1 (16 Dec 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-12/
- Q6: … 15.2 (20 Feb 2026). https://www.lightroomqueen.com/whats-new-in-lightroom-2026-02/
- Q7: … 15.3 (15 Apr 2026). https://www.lightroomqueen.com/whats-new-in-lightroom-2026-04/
- Q8: … 14.4 (17 Jun 2025, updated 31 Jul 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-06/
- Q9: … 14.5 (13 Aug 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-08/
- Q10: … 14.0 (14 Oct 2024, updated 21 Nov 2024). https://www.lightroomqueen.com/whats-new-in-lightroom-2024-10/
- Q11: … 14.1 (12 Dec 2024). https://www.lightroomqueen.com/whats-new-in-lightroom-2024-12/
- Q12: … 14.2 (13 Feb 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-02/
- Q13: … 13.2 (21 Feb 2024). https://www.lightroomqueen.com/whats-new-in-lightroom-2024-02/
- Q15: How do I find and move or rename my catalog? (14 Oct 2024). https://www.lightroomqueen.com/find-move-rename-catalog/
- Q16: What is a Lightroom catalog? (24 Feb 2020). https://www.lightroomqueen.com/what-is-a-lightroom-catalog/
- Q17: Lightroom Classic Catalogs, Top 10 Misunderstandings (29 Jul 2019). https://www.lightroomqueen.com/lightroom-catalogs-top-10-misunderstandings/
- Q18: Lightroom thinks my photos are missing, how do I fix it? (3 Jun 2019, updated 13 Jan 2026). https://www.lightroomqueen.com/lightroom-photos-missing-fix/
- Q19: The Dangers of Synchronize Folder (13 Jun 2016, updated 7 Dec 2022). https://www.lightroomqueen.com/synchronize-folder/
- Q20: Catalog corruption: how does it happen and can it be prevented? (20 Jan 2016, updated 10 Mar 2022). https://www.lightroomqueen.com/catalog-corruption-cause-prevention/
- Q21: Disaster strikes, a corrupted catalog! (8 Jul 2021). https://www.lightroomqueen.com/disaster-strikes-corrupted-catalog/
- Q22: How do I use my Lightroom catalog on multiple computers? (9 May 2016, updated 17 Aug 2024). https://www.lightroomqueen.com/how-to-lightroom-catalog-multiple-computers/
- Q23: Is it safe to store a Lightroom catalog on the new Dropbox macOS beta? (23 Mar 2023). https://www.lightroomqueen.com/catalog-on-dropbox-beta/
- Q24: Lightroom Performance: Previews & Caches (3 Jun 2021). https://www.lightroomqueen.com/lightroom-performance-previews-caches/
- Q25: Lightroom Performance: Preferences & Catalog Settings (25 May 2021), including 2017 replies by Victoria Bampton on what XMP omits. https://www.lightroomqueen.com/lightroom-performance-preferences-catalog-settings/
- Q26: Lightroom Performance: Debunking Myths (6 May 2021). https://www.lightroomqueen.com/lightroom-performance-debunking-myths/
- Q27: Lightroom Performance: Workflow Tweaks (18 Jun 2021). https://www.lightroomqueen.com/lightroom-performance-workflow-tweaks/
- Q28: Lightroom Performance: What's Slow? (22 Jun 2021). https://www.lightroomqueen.com/lightroom-performance-whats-slow/
- Q29: How do I create a Smart Collection? (24 Apr 2021). https://www.lightroomqueen.com/use-smart-collection/
- Q30: Why use collections to organize photos? (30 Jan 2017). https://www.lightroomqueen.com/collections-organize-photos/
- Q31: How do I copy keywords to a new catalog? (15 Feb 2023). https://www.lightroomqueen.com/copy-keywords-to-a-new-catalog/
- Q32: How do I clean up my keyword list? (27 May 2020). https://www.lightroomqueen.com/clean-keyword-list/
- Q33: Should I use flat or hierarchical keywords? (12 May 2020). https://www.lightroomqueen.com/flat-vs-hierarchical-keywords/
- Q34: How do I assign keywords to my photos? (19 May 2020). https://www.lightroomqueen.com/how-keyword-photos/
- Q35: The Power of the Painter Tool (9 Jan 2014, updated 24 Feb 2017). https://www.lightroomqueen.com/power-painter-tool/
- Q36: What do your Color Labels mean? (17 Jan 2014, updated 24 Feb 2017). https://www.lightroomqueen.com/color-labels-mean/
- Q37: How do I sync keywords between Classic and the Cloud ecosystem? (18 Jun 2026). https://www.lightroomqueen.com/sync-keywords/
- Q38: How do I clean up duplicate photos? (18 Mar 2019). https://www.lightroomqueen.com/clean-duplicate-photos/
- Q39: Lightroom cloud ecosystem vs. Lightroom Classic, feature table (15 Jan 2025, updated 30 Jul 2025). https://www.lightroomqueen.com/lightroom-cc-vs-classic-features/
- Q40: Should I move from Lightroom Classic to Lightroom Local? (13 Dec 2023, updated 23 May 2026). https://www.lightroomqueen.com/should-i-move-from-lightroom-classic-to-lightroom-local/
- Q41: What are the limitations of syncing Lightroom Classic with the cloud? (14 Mar 2024, updated 8 Jul 2026). https://www.lightroomqueen.com/limitations-syncing-classic-with-cloud/
- Q42: Why should I let Lightroom run its own backups? (24 Aug 2021). https://www.lightroomqueen.com/why-should-i-let-lightroom-run-its-own-backups/
- Q43: How often should I back up my catalog? (14 Feb 2022). https://www.lightroomqueen.com/catalog-back-frequency-keep/
- Q44: Should I convert to DNG? (13 Dec 2014, updated 21 Dec 2017). https://www.lightroomqueen.com/convert-dng/
- Q45: Adobe Lightroom Classic Keyboard Shortcuts, English (PDF, updated 13 Feb 2025). https://www.lightroomqueen.com/downloads/shortcuts/languages/en_US.pdf (index: https://www.lightroomqueen.com/keyboard-shortcuts/)
- Q46: How do I change or create keyboard shortcuts? (13 Mar 2017, updated 29 Apr 2025). https://www.lightroomqueen.com/custom-keyboard-shortcuts/
- Q47: How do I change Lightroom Classic Shortcuts? (28 Feb 2023). https://www.lightroomqueen.com/any-shortcut/
- Q48: What's new in Lightroom 6, face recognition, with reader comments (21 Apr 2015, updated 11 Dec 2024). https://www.lightroomqueen.com/whats-new-lightroom-cc-6-0/
- Q49: How do I search the cloud-based Lightroom apps? (11 Aug 2022). https://www.lightroomqueen.com/search-cloud-photos/
- Q50: How do I organize my photos with Lightroom Desktop (Cloud) / Mobile? (19 Jul 2022). https://www.lightroomqueen.com/organize-albums/
- Q51: Photo keyword ideas, on synonyms (7 May 2020, updated 2 Jun 2022). https://www.lightroomqueen.com/photo-keyword-ideas/

**The Lightroom Queen forums** (users' reports; scanned board: https://www.lightroomqueen.com/community/forums/lightroom-classic-folder-based-subscription.64/)

- F1: What is the upper limit for size of a catalog? (18 Mar 2025; includes Rikk Flohr's reply). https://www.lightroomqueen.com/community/threads/what-is-the-upper-limit-for-size-of-a-catalog-bad-performance-issues.52487/
- F2: Library Module, Qty of Folder Limitations for large DB (25 Jul 2025). https://www.lightroomqueen.com/community/threads/library-module-qty-of-folder-limitations-for-large-db.53211/
- F3: Catalog Size and Management? (18 Apr 2024). https://www.lightroomqueen.com/community/threads/catalog-size-and-management.50035/
- F4: Catalog Size (20 May 2026). https://www.lightroomqueen.com/community/threads/catalog-size.54801/
- F5: Lightroom catalog size is ballooning (16 Sep 2025). https://www.lightroomqueen.com/community/threads/lightroom-catalog-size-is-ballooning.53537/
- F6: New duplication detection tool (20 Jun 2026). https://www.lightroomqueen.com/community/threads/new-duplication-detection-tool.54947/
- F7: Has Keyword file format changed? (19 Apr 2024). https://www.lightroomqueen.com/community/threads/has-keyword-file-format-changed.50038/
- F8: Keyword import/export problem (13 May 2024). https://www.lightroomqueen.com/community/threads/keyword-import-export-problem.50161/
- F9: Folders with Exclamation Mark (Nov 2025). https://www.lightroomqueen.com/community/threads/folders-with-exclamation-mark.53833/
- F10: Missing folders after upgrading to LR Classic 15.0 (Oct 2025). https://www.lightroomqueen.com/community/threads/missing-folders-after-upgrading-to-lr-classic-15-0.53769/
- F11: Sooooo slow I'm starting to lose my love of photography (Feb 2025). https://www.lightroomqueen.com/community/threads/sooooo-slow-im-starting-to-lose-my-love-of-photography.52198/
- F12: My catalog is corrupted, AGAIN (Jun 2024). https://www.lightroomqueen.com/community/threads/my-catalog-is-corrupted-again.50298/
- F13: I store my LRC catalog in OneDrive; what problems might I encounter? (May 2024). https://www.lightroomqueen.com/community/threads/i-store-my-lrc-catalog-in-onedrive-what-problems-might-i-encounter.50105/
- F14: Using Lightroom on two machines (Nov 2024). https://www.lightroomqueen.com/community/threads/using-lightroom-on-two-machines.51636/
- F15: LrC unresponsive for a long time after import (Oct 2024). https://www.lightroomqueen.com/community/threads/lrc-unresponsive-for-a-long-time-after-import.51226/
- F16: Sync issues, suddenly (Jun 2024). https://www.lightroomqueen.com/community/threads/sync-issues-suddenly.50305/

**Fstoppers** (articles summarising videos)

- S2: Lightroom AI Culling Finds Sharp Keepers in Seconds (11 Dec 2025). https://fstoppers.com/lightroom/use-lightroom-ai-find-sharp-eyes-open-keepers-seconds-719139
- S3: Lightroom Classic February 2026: Firefly and Smart Culling (28 Feb 2026). https://fstoppers.com/lightroom/lightroom-classic-february-2026-update-firefly-webp-and-smarter-culling-900377

## Not reached

- **helpx.adobe.com** (HTTP 403 from Akamai): Adobe's help pages on the Library module, import, XMP, keywords, performance, network volumes and keyboard shortcuts, and its release notes. Adobe's wording on these topics was not checked.
- **www.adobe.com**: no response within 30 s.
- **DPReview** forums and news (HTTP 403, Cloudflare challenge).
- **PetaPixel** search, tag pages and feeds (HTTP 403, Cloudflare challenge).
- **The Lightroom Queen forum search** (HTTP 403, Cloudflare challenge); its board and thread pages did load.
- **Adobe Community search** renders in the browser and returned no results to curl; threads were found from the boards' listings instead.
- **Reddit**: not tried (the brief reports HTTP 403).
- **Search engines**, used only to find URLs: DuckDuckGo (bot challenge), Brave Search (CAPTCHA after one query); Bing ignored the query terms.
- **Not confirmed:** the bracket and brace notation in exported keyword files; whether the filmstrip follows the source in every module; face regions in XMP; whether Assisted Culling runs on the Mac.

[AD1]: https://community.adobe.com/announcements-673/lightroom-classic-v15-4-is-live-cull-people-shots-faster-auto-detect-duplicates-sync-keywords-everywhere-1627070
[AD2]: https://community.adobe.com/questions-675/early-access-assisted-culling-lrclassic-983825
[AD3]: https://community.adobe.com/questions-675/quick-tips-how-to-give-full-disk-access-to-lightroom-classic-on-macos-961364
[AD4]: https://community.adobe.com/members/rikk-flohr-retired-1348193
[FR1]: https://community.adobe.com/feature-requests-676/p-allow-catalog-to-be-stored-on-a-networked-drive-666362
[FR2]: https://community.adobe.com/feature-requests-676/p-ability-to-sync-lightroom-classic-keywords-with-the-lightroom-ecosystem-666425
[FR3]: https://community.adobe.com/feature-requests-676/p-include-additional-metadata-in-xmp-flags-collections-vc-s-etc-664991
[FR4]: https://community.adobe.com/feature-requests-676/p-allow-for-keyboard-shortcut-customization-666358
[FR5]: https://community.adobe.com/feature-requests-676/p-ability-to-sync-smart-collections-with-ecosystem-clients-665344
[FR6]: https://community.adobe.com/feature-requests-676/p-stacking-in-folders-and-collections-should-be-global-666404
[FR7]: https://community.adobe.com/feature-requests-676/p-better-auto-stacking-for-bracketing-hdr-focus-stacking-and-panoramas-666365
[FR8]: https://community.adobe.com/feature-requests-676/p-show-stack-in-smart-collections-665317
[FR9]: https://community.adobe.com/feature-requests-676/p-add-missing-photo-status-to-grid-filter-bar-and-smart-collections-665142
[FR10]: https://community.adobe.com/feature-requests-676/p-automatic-image-tagging-664740
[FR11]: https://community.adobe.com/feature-requests-676/p-allow-us-to-search-for-similar-photos-in-lightroom-classic-665403
[FR12]: https://community.adobe.com/feature-requests-676/p-sort-by-more-fields-sort-by-multiple-fields-664750
[FR13]: https://community.adobe.com/feature-requests-676/p-better-keyword-management-666408
[FR14]: https://community.adobe.com/feature-requests-676/p-allow-named-people-thumbnail-photo-to-be-changed-664847
[FR15]: https://community.adobe.com/feature-requests-676/p-allow-facial-recognition-feature-to-re-index-a-folder-collection-664812
[FR16]: https://community.adobe.com/feature-requests-676/p-openstreetmap-osm-as-map-style-in-map-module-665662
[FR17]: https://community.adobe.com/feature-requests-676/p-gps-track-limited-to-50-000-points-665226
[FR18]: https://community.adobe.com/feature-requests-676/p-add-option-to-import-raw-only-665061
[FR19]: https://community.adobe.com/feature-requests-676/p-delete-images-on-card-after-import-666337
[FR20]: https://community.adobe.com/feature-requests-676/p-store-the-xmp-metadata-outside-dng-jpeg-etc-file-to-be-backup-efficient-665133
[FR21]: https://community.adobe.com/feature-requests-676/p-show-parent-folders-by-default-665056
[FR22]: https://community.adobe.com/feature-requests-676/p-build-library-previews-in-the-background-regardless-of-their-having-been-visible-666071
[FR23]: https://community.adobe.com/feature-requests-676/p-ai-blob-storage-size-should-be-limited-and-automatically-cleaned-up-like-previews-666187
[FR24]: https://community.adobe.com/feature-requests-676/p-merge-duplicate-keywords-in-lightroom-list-665316
[FR25]: https://community.adobe.com/feature-requests-676/p-better-support-for-keyword-synonyms-664870
[FR26]: https://community.adobe.com/feature-requests-676/p-auto-locate-moved-files-in-library-664899
[FR27]: https://community.adobe.com/feature-requests-676/p-relink-multiple-folders-at-a-time-666127
[FR28]: https://community.adobe.com/feature-requests-676/p-built-in-duplicate-finder-666195
[FR29]: https://community.adobe.com/feature-requests-676/p-i-would-like-to-synchronize-over-lan-cable-instead-of-internet-665276
[FR30]: https://community.adobe.com/feature-requests-676/p-multiple-catalog-syncing-665134
[BR1]: https://community.adobe.com/bug-reports-674/p-performance-slow-on-large-catalog-540k-images-crash-9690382-664319
[BR2]: https://community.adobe.com/bug-reports-674/p-lrc-12-2-1-fails-to-start-launch-or-is-extremely-slow-launching-664007
[BR3]: https://community.adobe.com/bug-reports-674/p-adding-to-creation-of-a-new-target-collection-takes-minutes-unless-sync-is-paused-664315
[BR4]: https://community.adobe.com/bug-reports-674/p-constantly-saving-xmp-for-xx-photos-slowing-down-my-lightroom-classic-664312
[BR5]: https://community.adobe.com/bug-reports-674/p-windows-panel-is-limited-to-1600-items-folders-keywords-etc-663697
[BR6]: https://community.adobe.com/bug-reports-674/p-synchronize-folder-incorrectly-shows-photos-as-missing-664142
[BR7]: https://community.adobe.com/bug-reports-674/p-loses-connection-with-files-after-folder-is-renamed-662986
[BR8]: https://community.adobe.com/bug-reports-674/p-message-the-catalog-could-not-be-opened-due-to-an-unexpected-error-662989
[BR9]: https://community.adobe.com/bug-reports-674/p-after-the-new-version-update-today-unexpected-error-opening-catalog-663037
[BR10]: https://community.adobe.com/bug-reports-674/p-lrcat-data-folder-missing-from-backup-zip-files-663924
[BR11]: https://community.adobe.com/bug-reports-674/p-lrc-15-4-15-4-1-cannot-create-catalog-backups-directly-on-smb-nas-shares-backup-fails-during-compression-1628839
[BR12]: https://community.adobe.com/bug-reports-674/p-map-module-will-not-load-google-maps-664049
[BR13]: https://community.adobe.com/bug-reports-674/p-map-appears-all-grey-with-high-latency-network-connections-to-google-s-servers-664429
[BR14]: https://community.adobe.com/bug-reports-674/p-photo-placed-in-wrong-spot-on-map-664029
[BR15]: https://community.adobe.com/bug-reports-674/p-import-is-creating-os-level-duplicate-files-named-2-when-using-devices-rather-than-files-663993
[BR16]: https://community.adobe.com/bug-reports-674/p-custom-order-lost-with-slight-accidental-movement-of-thumbnail-in-filmstrip-663881
[BR17]: https://community.adobe.com/bug-reports-674/p-delete-rejected-photos-in-duplicates-view-deletes-all-copies-1628661
[BR18]: https://community.adobe.com/bug-reports-674/p-library-previews-not-updating-663816
[BR19]: https://community.adobe.com/bug-reports-674/p-limit-of-52-reorderings-in-custom-ordered-collections-and-folders-663977
[BR20]: https://community.adobe.com/bug-reports-674/p-lightroom-classic-no-longer-syncs-completely-successfully-663016
[BR21]: https://community.adobe.com/bug-reports-674/p-import-keyword-synonyms-problem-663895
[BR22]: https://community.adobe.com/bug-reports-674/p-unable-to-advance-to-the-next-photo-664118
[BR23]: https://community.adobe.com/bug-reports-674/p-map-module-keeps-flashing-map-offline-when-it-s-not-663652
[QA1]: https://community.adobe.com/questions-675/experiencing-performance-related-issues-in-lightroom-4-x-987414
[QA2]: https://community.adobe.com/questions-675/how-do-i-remove-duplicates-in-my-lightroom-catalogue-952311
[QA3]: https://community.adobe.com/questions-675/metadata-errors-and-issues-in-lr-classic-cc-on-nas-933002
[QA4]: https://community.adobe.com/questions-675/lightroom-onedrive-a-match-made-in-heaven-945384
[QA5]: https://community.adobe.com/questions-675/lightroom-encountered-and-error-when-reading-from-its-preview-cache-and-needs-to-quit-938424
[Q1]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-06/
[Q2]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-08/
[Q3]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-09/
[Q4]: https://www.lightroomqueen.com/whats-new-in-lightroom-2025-10/
[Q5]: https://www.lightroomqueen.com/whats-new-in-lightroom-2025-12/
[Q6]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-02/
[Q7]: https://www.lightroomqueen.com/whats-new-in-lightroom-2026-04/
[Q8]: https://www.lightroomqueen.com/whats-new-in-lightroom-2025-06/
[Q9]: https://www.lightroomqueen.com/whats-new-in-lightroom-2025-08/
[Q10]: https://www.lightroomqueen.com/whats-new-in-lightroom-2024-10/
[Q11]: https://www.lightroomqueen.com/whats-new-in-lightroom-2024-12/
[Q12]: https://www.lightroomqueen.com/whats-new-in-lightroom-2025-02/
[Q13]: https://www.lightroomqueen.com/whats-new-in-lightroom-2024-02/
[Q15]: https://www.lightroomqueen.com/find-move-rename-catalog/
[Q16]: https://www.lightroomqueen.com/what-is-a-lightroom-catalog/
[Q17]: https://www.lightroomqueen.com/lightroom-catalogs-top-10-misunderstandings/
[Q18]: https://www.lightroomqueen.com/lightroom-photos-missing-fix/
[Q19]: https://www.lightroomqueen.com/synchronize-folder/
[Q20]: https://www.lightroomqueen.com/catalog-corruption-cause-prevention/
[Q21]: https://www.lightroomqueen.com/disaster-strikes-corrupted-catalog/
[Q22]: https://www.lightroomqueen.com/how-to-lightroom-catalog-multiple-computers/
[Q23]: https://www.lightroomqueen.com/catalog-on-dropbox-beta/
[Q24]: https://www.lightroomqueen.com/lightroom-performance-previews-caches/
[Q25]: https://www.lightroomqueen.com/lightroom-performance-preferences-catalog-settings/
[Q26]: https://www.lightroomqueen.com/lightroom-performance-debunking-myths/
[Q27]: https://www.lightroomqueen.com/lightroom-performance-workflow-tweaks/
[Q28]: https://www.lightroomqueen.com/lightroom-performance-whats-slow/
[Q29]: https://www.lightroomqueen.com/use-smart-collection/
[Q30]: https://www.lightroomqueen.com/collections-organize-photos/
[Q31]: https://www.lightroomqueen.com/copy-keywords-to-a-new-catalog/
[Q32]: https://www.lightroomqueen.com/clean-keyword-list/
[Q33]: https://www.lightroomqueen.com/flat-vs-hierarchical-keywords/
[Q34]: https://www.lightroomqueen.com/how-keyword-photos/
[Q35]: https://www.lightroomqueen.com/power-painter-tool/
[Q36]: https://www.lightroomqueen.com/color-labels-mean/
[Q37]: https://www.lightroomqueen.com/sync-keywords/
[Q38]: https://www.lightroomqueen.com/clean-duplicate-photos/
[Q39]: https://www.lightroomqueen.com/lightroom-cc-vs-classic-features/
[Q40]: https://www.lightroomqueen.com/should-i-move-from-lightroom-classic-to-lightroom-local/
[Q41]: https://www.lightroomqueen.com/limitations-syncing-classic-with-cloud/
[Q42]: https://www.lightroomqueen.com/why-should-i-let-lightroom-run-its-own-backups/
[Q43]: https://www.lightroomqueen.com/catalog-back-frequency-keep/
[Q44]: https://www.lightroomqueen.com/convert-dng/
[Q45]: https://www.lightroomqueen.com/downloads/shortcuts/languages/en_US.pdf
[Q46]: https://www.lightroomqueen.com/custom-keyboard-shortcuts/
[Q47]: https://www.lightroomqueen.com/any-shortcut/
[Q48]: https://www.lightroomqueen.com/whats-new-lightroom-cc-6-0/
[Q49]: https://www.lightroomqueen.com/search-cloud-photos/
[Q50]: https://www.lightroomqueen.com/organize-albums/
[Q51]: https://www.lightroomqueen.com/photo-keyword-ideas/
[F1]: https://www.lightroomqueen.com/community/threads/what-is-the-upper-limit-for-size-of-a-catalog-bad-performance-issues.52487/
[F2]: https://www.lightroomqueen.com/community/threads/library-module-qty-of-folder-limitations-for-large-db.53211/
[F3]: https://www.lightroomqueen.com/community/threads/catalog-size-and-management.50035/
[F4]: https://www.lightroomqueen.com/community/threads/catalog-size.54801/
[F5]: https://www.lightroomqueen.com/community/threads/lightroom-catalog-size-is-ballooning.53537/
[F6]: https://www.lightroomqueen.com/community/threads/new-duplication-detection-tool.54947/
[F7]: https://www.lightroomqueen.com/community/threads/has-keyword-file-format-changed.50038/
[F8]: https://www.lightroomqueen.com/community/threads/keyword-import-export-problem.50161/
[F9]: https://www.lightroomqueen.com/community/threads/folders-with-exclamation-mark.53833/
[F10]: https://www.lightroomqueen.com/community/threads/missing-folders-after-upgrading-to-lr-classic-15-0.53769/
[F11]: https://www.lightroomqueen.com/community/threads/sooooo-slow-im-starting-to-lose-my-love-of-photography.52198/
[F12]: https://www.lightroomqueen.com/community/threads/my-catalog-is-corrupted-again.50298/
[F13]: https://www.lightroomqueen.com/community/threads/i-store-my-lrc-catalog-in-onedrive-what-problems-might-i-encounter.50105/
[F14]: https://www.lightroomqueen.com/community/threads/using-lightroom-on-two-machines.51636/
[F15]: https://www.lightroomqueen.com/community/threads/lrc-unresponsive-for-a-long-time-after-import.51226/
[F16]: https://www.lightroomqueen.com/community/threads/sync-issues-suddenly.50305/
[S2]: https://fstoppers.com/lightroom/use-lightroom-ai-find-sharp-eyes-open-keepers-seconds-719139
[S3]: https://fstoppers.com/lightroom/lightroom-classic-february-2026-update-firefly-webp-and-smarter-culling-900377
