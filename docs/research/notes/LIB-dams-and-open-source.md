# Library research: open-source photo managers, DAMs and other editors' libraries

Evidence for the library research study (LIB-01): how darktable, digiKam, five digital asset managers (DAMs) and the libraries of four editors organise, search and keep track of photos, with the focus on scale, network storage, search, and files moved outside the app. Lightroom Classic, Capture One, Photo Mechanic and Bridge are in other notes.

All sources were checked on **2026-10-05**, and each fact gives its version or date. Bracketed IDs link to the [sources](#6-sources), and "(unverified)" marks what we could not confirm. We read documentation, release notes, issues and forums, not source code.

---

## 1. Summary

1. **Most of these products keep a database as the record and treat sidecars as copies.** The exceptions are ON1, which keeps edits in `.on1` sidecars, and NeoFinder, which writes XMP straight into files [DT4], [OR1], [NF11].
2. **Files moved or renamed outside the app are the most common complaint** (7 of 11 products). Only digiKam re-finds them unaided, by file size plus a partial hash [DK10], [IM7], [DX3].
3. **Start-up checks grow with the library and are worst on network volumes.** darktable's took 58 s per cold start for 84,924 images on NFS, and about 3 s once 5.8 listed each folder once, in parallel and in the background [DT14], [DT15].
4. **The largest libraries reported**: digiKam above 1,000,000 items on SQLite; IMatch above a million (most users have 80,000–150,000); Photo Supreme tested at 700,000; darktable above 389,000 [DK2], [IM12], [PS1], [DT22].
5. **Search at that scale takes seconds.** IMatch says search time grows in proportion to size, about 1 s per 100,000 files; Photo Supreme took 2–7 s at 700,000 and caps live results at 2,000 [IM12], [PS1], [PS6].
6. **Databases stay off the network.** Apple, digiKam and IMatch advise against keeping a library or database on a share, and digiKam's clients cannot share a database at the same time [AP8], [DK2], [DK3], [IM10].
7. **Ingestion that blocks the user is the next complaint**: up to 15 minutes before one photo could be edited (DxO), cataloging that never ends (ON1), hours of rescanning when the NAS was off (digiKam) [DX5], [OR2], [DK16].
8. **Working from disconnected drives is a core DAM feature** (NeoFinder, Photo Supreme, IMatch, Peakto Search); darktable keeps thumbnails only with its disk cache turned on [NF1], [PS4], [IM7], [PK3], [DT8].
9. **Expressive search exists, but each app splits it across tools**: rules and filters (darktable), grouped Advanced Search (digiKam), a Boolean and regex search bar beside stored filters (IMatch), a search box beside a query panel (Photo Supreme) [DT1], [DK5], [IM3], [PS7].
10. **AI features run on the computer**: faces, auto-keywords kept apart from the user's own, similarity, text in photos, and natural language turned into an editable query (digiKam 9.2) [DK7], [DK12], [DK15], [EX2], [AP2].
11. **Duplicate finding needs two tiers.** Exact copies by hash are quick; digiKam's all-pairs similarity search had covered 4% of 286,583 images after 20 hours [IM2], [NF8], [DK18].
12. **digiKam's Advanced Rename is the model for naming templates**: tokens for file, folder, date and metadata, counters, case changes and regular-expression replacement, shared by renaming, import and batch work [DK9].

## 2. At a glance

| Product (version) | Record and sidecars | Changes made outside | Network | Largest reported |
|---|---|---|---|---|
| darktable 5.6 | `library.db`; `name.ext.xmp`; database wins | Not watched; optional start-up check | Start-up check slow on NFS and SMB | Over 389,000 (2021) |
| digiKam 9.1 | SQLite or MariaDB; XMP in files or sidecars | Optional scans; moves re-found by hash | Photos on shares, database local | Over 1,000,000 |
| IMatch 2026 (Windows) | Database; ExifTool write-back | Windows notifications; moved folders offline | Database on a NAS discouraged | Over 1,000,000 |
| Photo Supreme 2026 | SQLite, PostgreSQL or SQL Server | Folder Verification, run by hand | Server edition maps Mac and Windows paths | 700,000 (vendor test) |
| NeoFinder 9.3 (macOS) | One catalog per volume; XMP into files | Update Catalog, by hand or scheduled | Catalogs SMB, AFP, NAS and FTP | Many millions of files |
| Peakto 2.7 (macOS) | Index over other apps' catalogs | (unverified) | NAS sources | 350,000 (user) |
| Excire Foto 2027 | Database; XMP (unverified) | (unverified) | One user at a time on a network database | (unverified) |
| Apple Photos 12 (macOS 27) | Library package; no sidecars | Moved referenced files lost | Library not on a share | Not stated |
| ACDSee for Mac 26 | Database plus metadata in files | Catalogs while idle | Browses network places | (unverified) |
| ON1 Photo RAW 2026 | `.on1` sidecars; optional catalog | Cataloged folders monitored | Photos on network drives (2016 claim) | "Hundreds of thousands" (vendor) |
| DxO PhotoLab 9 | Database; `.dop` and XMP optional | Rescans a folder when opened | NAS folders slow to open | 25,000 re-indexed in under 10 min (user) |

## 3. Products

### 3.1 darktable 5.6 (Linux, macOS, Windows)

- **Organisation.** Each imported folder is a *film roll*, and the lighttable shows a *collection*, by default the last film roll. *add to library* indexes files in place; *copy & import* copies and names them from variables such as `$(YEAR)` and `$(SEQUENCE)`. Nothing watches the file system [DT10], [DT9].
- **Search.** A collection is a list of rules over nearly 40 attributes: folder, tag, metadata, rating, colour label, dates, EXIF and applied modules. Each rule is a `%` pattern, a comparison or a `[from;to]` range, joined to the others by AND, OR or EXCEPT [DT1]. The *collection filters* module adds pinned range widgets with histograms, a fuzzy text search and multi-key sorts [DT2].
- **Tags.** Tags are pipe-separated paths (`places|France|Nord`). Each can be marked as a category or as private and given synonyms, and Lightroom keyword files import and export. darktable also attaches its own `darktable|…` tags [DT3].
- **Sidecars and moves.** `name.ext.xmp` is written on import; Lightroom's `name.xmp` is read but never written [DT4], [DT5]. The database wins: edits other apps make to the XMP are overwritten unless the optional start-up check is on [DT4], [DT6], and darktable writes a sidecar without first comparing timestamps [DT14]. A missing file shows a skull, and *update path to files…* repoints its folder [DT8], [DT1]. *Local copies* cache photos for travel [DT7].
- **Scale.** 4.6 (2023) fixed scrolling at about 50,000 images, 4.8 (2024) made the map usable with a million geotagged photos, and 5.4 (2025) sped up first start-up on a hard disk or NAS [DT11], [DT12], [DT13]. In 3.4 (2021), a 183,000-photo library slowed a 128-photo import from 4 s to 1 min 53 s [DT22]. With the start-up check on, an SMB share took 10–15 minutes to launch (2024), and a 486,557-photo NFS archive 2–3 minutes (2026) [DT16], [DT17]. One user's index took about 13 KB per image (2022) [DT24].
- **Praise and complaints.** A user praised how its asset management had matured (2022) [DT24]. Complaints: folders that keep going missing [DT23], changes from other apps ignored [DT18], and no support for working on two computers [DT19], [DT20].

### 3.2 digiKam 9.1 (Linux, macOS, Windows)

- **Organisation.** Albums are folders under root collections (local, removable or network), each tied to a volume UUID that *Update Path* changes [DK3]. Four databases (core, thumbnails, similarity fingerprints and faces) live in SQLite or MariaDB, and MySQL support ends in 9.2.0 [DK1], [DK2].
- **Search.** Quick Search ANDs words across all metadata and saves live searches. Advanced Search nests groups that match all, any, none or not all of their fields [DK5]. A local LLM that turns plain requests into Advanced Search criteria arrives in 9.2.0 [DK15].
- **Similarity, faces and maps.** Haar-wavelet fingerprints drive duplicate, similar-image and sketch search, comparing every image with every other [DK6]. Faces use YuNet and SFace, in a pipeline rewritten for 8.6 (2025) [DK13]. Auto-tags go under an `auto` branch [DK12], and a map search selects photos by area [DK8].
- **Metadata and renaming.** Tags, labels, captions, face regions and GPS can go into files or into `name.ext.xmp` or `name.xmp` sidecars, with read priorities per field and optional deferred writes [DK4]. Advanced Rename combines tokens, metadata fields, counters and modifiers such as `{unique}` and `{replace:…,r}` [DK9].
- **Moves and scale.** Files are identified by size plus a partial hash, which re-finds files moved outside [DK10]. Scanning at start-up is optional [DK11]. SQLite with WAL serves over 500,000 items and users report a million; SQLite cannot live on NFS, and two clients cannot use one database at the same time [DK2], [DK3]. Folder monitoring is slow on macOS and on network file systems [DK3].
- **Praise and complaints.** Users praise its geolocation and tagging tools [DK16], [DT22]. Complaints: hours of rescanning when a NAS holding 120,000 photos was off at launch [DK16], shares dropping offline under load [DK17], 20 hours to cover 4% of a 286,583-image duplicate search [DK18], and tag writes slow enough to defer [DK19]. A 20-person team with 2.5 million images got no developer answer [DK20]. 9.1 fixed photos that seemed lost with MariaDB on a NAS [DK14].

### 3.3 IMatch 2026 (Windows)

- **Organisation.** IMatch indexes folders in place, storing each file's metadata, thumbnail, checksum and visual data. Categories can be manual, data-driven or formulas, beside an automatic keyword tree [IM1], [IM5].
- **Search.** The search bar searches the current scope or the whole database over chosen tag sets, in Boolean, exact-phrase, regex or inverted mode; searching all metadata is documented as slow [IM3]. The Filter Panel stores filters for later combination [IM13]. *Duplicates* compares image fingerprints and *Copies* compares bytes [IM2]. An experimental semantic search uses embeddings [IM4]. The current help does not mention "Universal Search", which may be an earlier name (unverified).
- **AI.** AutoTagger runs a local model (Ollama) or a cloud service and stores its results in AI tags; faces are recognised locally [IM6], [IM3].
- **Changes made outside.** Windows change notifications and folder dates trigger rescans [IM9]. Folders that were moved, renamed or restored to a new disk go offline, keeping their data, until *Relocate* points them at the new place; each file has a lifetime GUID [IM7], [IM8]. ExifTool writes metadata back to files or XMP sidecars [IM11].
- **Scale.** Most users have 80,000–150,000 files and some over a million. Work grows in proportion: a search that takes 1 s over 100,000 files takes about 5 s over 500,000. For a million files the developer advises 32 GB of RAM and a fast SSD [IM12], and the database belongs on a local SSD, not on a NAS [IM10].
- **Praise and complaints.** The community forum refuses searches from guests, so we found no user reports.

### 3.4 Photo Supreme 2026 (macOS, Windows, Linux)

The catalog (SQLite, or PostgreSQL or SQL Server for concurrent users) is what the user browses. Missing or offline folders turn red, and *Folder Verification* reports changes made outside [PS1], [PS4], [PS5]. Photo Supreme builds its own token index, not the database's full-text search, so every database engine gives the same results. One search box suggests matches, grouped by domain, as you type. Advanced Search adds AND, OR and counts of values, with live results capped at 2,000, and a drag-and-drop panel builds grouped queries that can be saved as Favorites [PS2], [PS8], [PS6], [PS7]. Writing XMP is optional, and the Server Edition maps Mac and Windows paths to the same files [PS3], [PS9].

In the vendor's informal test (version 2026.3.2, SQLite, NVMe SSD), 160,000 photos opened in 5.5 s, and a 700,000-photo view was capped at its first 250,000. Global searches took 2–7 s and label lookups under 0.5 s, and memory stayed near 1.1 GB [PS1]. Testimonials praise its reliability [PS10]; we searched no forum.

### 3.5 NeoFinder 9.3 (macOS)

NeoFinder keeps one catalog file per volume, with thumbnails and metadata. Volumes can be disks, SMB, AFP or NAS shares, FTP, cloud storage, optical discs or LTO tapes, and a catalog can be browsed while its volume is disconnected [NF1], [NF13], [NF4]. Changes arrive only through *Update Catalog* or a scheduled AutoUpdater, and moved data is repointed with *Reconnect Catalog…* [NF4], [NF5], [NF6]. The Find Editor combines up to 16 criteria; QuickFind searches every catalog, and slows when there are thousands of them [NF7], [NF3]. Some customers have 57,000 catalogs, or catalogs of many millions of files [NF2]. Duplicates match by name or MD5, similar photos come from Vision, and face detection does not identify people [NF8], [NF9], [NF10]. XMP goes into JPEG, PNG, DNG, TIFF and MOV files, and into `name.xmp` sidecars for other formats [NF11]; a database folder on a server can be shared by several Macs [NF12]. Testimonials praise its search and its view of offline drives [NF1].

### 3.6 Peakto and Excire

Peakto 2.7 (February 2026) indexes Photos, Aperture, Lightroom Classic, Capture One, Luminar and iView catalogs, as well as folders. It adds local AI search, faces and duplicates, can sync annotations back to Lightroom and Capture One, and ships compatibility updates for new Capture One and Photos releases [PK1], [PK4]. Its Lightroom plug-in, Peakto Search, works offline and searches disconnected catalogs [PK3]. A user praises having 350,000 photos in one place [PK2].

Excire Foto 2027 (June 2026) offers local free-text, people, duplicate and aesthetic search, and now also finds text inside photos [EX1], [EX2]. Excire Search 2026 does the same inside Lightroom Classic with its own database, and a reviewer credits it with saving hours [EX3], [EX5]. The Office edition's network database admits one user at a time [EX4]. How Excire writes XMP is unverified.

### 3.7 Apple Photos 12 (macOS 27)

Photos copies imports into its library unless *Copy items to the Photos library* is turned off. Files left in place, called referenced files, stay out of iCloud and library backups, and are lost to Photos if moved or renamed in Finder; *Consolidate* copies them into the library [AP1]. Apple advises against keeping the library on network, flash or cloud-synced storage; if its drive is missing at launch, Photos starts a new empty library [AP8]. Search covers titles, captions, keywords, dates and text in photos, and Apple Intelligence descriptions in some languages [AP2]. People & Pets, a map, merged duplicates, Smart Albums matching any or all conditions, flat keywords and star ratings complete it [AP3], [AP4], [AP5], [AP6], [AP7], [AP10]. Photos writes no sidecars, but can export IPTC data as XMP beside an unmodified original [AP9]. Apple states no size limit, and its forum was unreachable.

### 3.8 ACDSee for Mac 26, ON1 Photo RAW 2026, DxO PhotoLab 9

- **ACDSee for Mac 26** browses local, removable and network folders without import, catalogs while the Mac is idle, and can keep several databases. It has hierarchical keywords and categories, AI keywords, faces, Quick Search, saved searches, duplicates and Lightroom import; Advanced Search with AND and OR is listed for Windows only [AC2], [AC3], [AC1]. Its help site refused us, so how it handles moved files is unverified.
- **ON1 Photo RAW 2026** browses folders directly or catalogs them for search, and monitors cataloged folders. Edits live in `.on1` sidecars, so folders can move, but photos moved outside show as missing until the user browses to them [OR1], [OR5]. 2024 added control over preview size and scanning load, and 2027 adds actions on watched folders [OR3], [OR4]. A user praises the optional catalog [OR1]; others report cataloging stuck at 99% (2018), endlessly restarting (2019) and slowing the whole computer (2025) [OR2].
- **DxO PhotoLab 9** (9.9 in July 2026; DxO's site refused us) indexes folders into a database, writes optional `.dop` sidecars and can sync metadata with XMP [DX7], [DX8]. A photo's identity is its path. Files moved outside reappear as duplicates marked with question marks, users could not find the folder relocation advertised for version 9, and a volume restored with a new UUID was fixed only by deleting the database and re-indexing (25,000 photos in under 10 minutes) [DX3], [DX4], [DX1], [DX2]. Folders are rescanned when opened, and previews for the whole folder come first: one user waited up to 15 minutes to edit a photo in a 3,000-image NAS folder, while praising the results [DX6], [DX5], [DX10]. Projects are links to the originals, so an edit in one project shows in all of them [DX9].

## 4. Recurring complaints, ranked

Ranked by the number of products for which we found the complaint.

1. **Files moved or renamed outside the app are lost, duplicated or orphaned** (7 products): darktable [DT23], [DT8]; DxO [DX3], [DX2], [DX4]; ON1 [OR1]; Apple Photos [AP1]; IMatch [IM7]; Photo Supreme [PS4]; NeoFinder [NF6].
2. **Start-up checks and rescans grow with the library and block work** (5): darktable [DT14], [DT16], [DT17]; digiKam [DK16]; DxO [DX6], [DX5]; ON1 [OR2]; IMatch [IM9].
3. **Network storage is slow or unsupported** (5): darktable [DT16], [DT21]; digiKam [DK17], [DK14], [DK3]; Apple [AP8]; IMatch [IM10]; DxO [DX5].
4. **Bulk work is slow at scale**, from duplicate searches and tag writes to imports and global search (4): digiKam [DK18], [DK19]; darktable [DT22]; IMatch [IM12]; Photo Supreme [PS1].
5. **Two computers or a team cannot share a library** (4): darktable [DT19], [DT20]; digiKam [DK3], [DK20]; Excire [EX4]; IMatch [IM8].
6. **Sidecars and the database disagree** (2): darktable [DT4], [DT18], [DT14]; DxO [DX7], [DX4].

## 5. Recommendations for Redlamp

| # | Recommendation | Verdict | Why | Rows |
|---|---|---|---|---|
| 1 | Never block launch, or the photo being opened, on file checks: list each folder once, check network volumes in parallel, recent folders first (darktable 5.8) | Adopt | It cut a cold start on NFS from 58 s to about 3 s [DT15] | LIB-07, LIB-08 |
| 2 | Before writing a sidecar, check it is unchanged (date and hash, under file coordination); if it changed, merge per key | Do better | darktable overwrites newer sidecars silently, and DxO users distrust XMP sync [DT14], [DX7] | LIB-11, LIB-24 |
| 3 | Match moved files by a photo ID in the `.redlamp` sidecar, then by file identity, then by size plus partial hash | Do better | Moves top the complaints, and only digiKam re-finds files unaided [DK10] | LIB-08 |
| 4 | Re-match a restored or copied volume by its folders and photo IDs, not only its UUID, and keep a Relocate command | Do better | A new UUID orphans DxO's and IMatch's records [DX2], [IM7] | LIB-08 |
| 5 | Browse offline volumes from stored thumbnails, showing each folder's state | Adopt | DAM users rely on it [NF1], [PS4], [IM7] | LIB-09 |
| 6 | Index behind the screen: the photo being opened, then visible cells, then the rest; an unreachable volume is offline, never deleted | Do better | DxO, ON1 and digiKam keep users waiting for minutes to hours [DX5], [OR2], [DK16] | LIB-07, LIB-16 |
| 7 | Keep the index on the Mac's own disk | Adopt | Apple, digiKam and IMatch warn against databases on a network [AP8], [DK2], [IM10] | LIB-05 |
| 8 | Search as you type over 1,000,000 photos, with counts and no cap on results | Build | No product documents it; the nearest take seconds and cap results [IM12], [PS1], [PS6] | LIB-06, LIB-10, LIB-18 |
| 9 | One query language whose text and rule-editor forms are interchangeable, with darktable's AND, OR and EXCEPT, ranges, and digiKam's grouped conditions | Do better | The semantics exist but are split across tools [DT1], [DT2], [DK5] | LIB-06, LIB-23 |
| 10 | Hierarchical keywords with category, private and synonym flags, Lightroom keyword files, and read priorities per field for other apps' XMP | Adopt | darktable and digiKam show the model and how it maps to XMP [DT3], [DK4] | LIB-21, LIB-24 |
| 11 | Internal state stored as keywords (`darktable\|exported`) | Skip | Redlamp's own fields keep keyword lists and exports clean [DT3] | LIB-21 |
| 12 | digiKam's rename tokens and modifiers as the minimum template language, with Redlamp's preview and journal | Adopt | One syntax serves renaming, import and batch work [DK9] | LIB-25, LIB-26 |
| 13 | Find duplicates in two tiers: hashes first, then Vision feature prints looked up through an index | Do better | All-pairs comparison took 20 hours for 4% of 286,583 photos [DK18], [IM2] | LIB-31 |
| 14 | Keep AI suggestions apart until accepted, and show natural language as an editable query | Adopt | digiKam and IMatch do both locally [DK12], [DK15], [IM3] | LIB-32, LIB-33 |
| 15 | A shared multi-user database | Skip | The index is per Mac and rebuildable, and sidecars travel with the photos [DK3], [EX4] | DEC-42 |
| 16 | Live two-way sync with other apps' catalogs, as in Peakto | Skip | Import from a copy instead: private formats need an update for each new release [PK1] | LIB-29, LIB-30 |

## 6. Sources

All checked 2026-10-05.

**darktable** (user manual 5.6; 5.6.2 was released on 2026-10-04)

- [DT1] Collections module. https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/shared/collections/
- [DT2] Collection filters module. https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/shared/collection-filters/
- [DT3] Tagging module. https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/shared/tagging/
- [DT4] Sidecar files. https://docs.darktable.org/usermanual/5.6/en/overview/sidecar-files/sidecar/
- [DT5] Importing sidecar files generated by other applications. https://docs.darktable.org/usermanual/5.6/en/overview/sidecar-files/sidecar-import/
- [DT6] Preferences: storage. https://docs.darktable.org/usermanual/5.6/en/preferences-settings/storage/
- [DT7] Local copies. https://docs.darktable.org/usermanual/5.6/en/overview/sidecar-files/local-copies/
- [DT8] Thumbnails. https://docs.darktable.org/usermanual/5.6/en/lighttable/digital-asset-management/thumbnails/
- [DT9] Import module. https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/lighttable/import/
- [DT10] Collections and film rolls. https://docs.darktable.org/usermanual/5.6/en/lighttable/digital-asset-management/collections/
- [DT11] Release notes 4.6.0 (2023-12-21). https://github.com/darktable-org/darktable/releases/tag/release-4.6.0
- [DT12] Release notes 4.8.0 (2024-06-21). https://github.com/darktable-org/darktable/releases/tag/release-4.8.0
- [DT13] Release notes 5.4.0 (2025-12-21). https://github.com/darktable-org/darktable/releases/tag/release-5.4.0
- [DT14] Issue #21849, start-up crawl on large libraries (2026-08-15). https://github.com/darktable-org/darktable/issues/21849
- [DT15] Pull request #21850, crawl in parallel and in the background (merged 2026-08-22, milestone 5.8). https://github.com/darktable-org/darktable/pull/21850
- [DT16] Issue #17215, start-up check on a CIFS share (2024-07-27). https://github.com/darktable-org/darktable/issues/17215
- [DT17] Issue #21268, background sidecar updates (2026-06-07). https://github.com/darktable-org/darktable/issues/21268
- [DT18] Issue #19728, sidecars changed by other software not reloaded (2025-11-13). https://github.com/darktable-org/darktable/issues/19728
- [DT19] Issue #18253, two computers and one drive (2025-01-20). https://github.com/darktable-org/darktable/issues/18253
- [DT20] Issue #18599, sync the library across clients (2025-03-23). https://github.com/darktable-org/darktable/issues/18599
- [DT21] Issue #16091, unable to add a network folder (2024-01-12). https://github.com/darktable-org/darktable/issues/16091
- [DT22] discuss.pixls.us, Slow image import to a large library (2021-01). https://discuss.pixls.us/t/slow-image-import-to-a-large-library/22327
- [DT23] discuss.pixls.us, darktable keeps losing my files (2024-01). https://discuss.pixls.us/t/darktable-keeps-losing-my-files-forcing-a-re-import/41496
- [DT24] discuss.pixls.us, export into the library (2022-07; posts 3 and 7). https://discuss.pixls.us/t/how-do-i-propose-a-change-to-export-function-to-add-images-to-library-upon-export/31518

**digiKam** (online handbook, which already describes 9.2.0 changes; news posts)

- [DK1] Database. https://docs.digikam.org/en/getting_started/database_intro.html
- [DK2] Database settings. https://docs.digikam.org/en/setup_application/database_settings.html
- [DK3] Collections settings. https://docs.digikam.org/en/setup_application/collections_settings.html
- [DK4] Metadata settings. https://docs.digikam.org/en/setup_application/metadata_settings.html
- [DK5] Search view. https://docs.digikam.org/en/left_sidebar/search_view.html
- [DK6] Similarity view. https://docs.digikam.org/en/left_sidebar/similarity_view.html
- [DK7] People view. https://docs.digikam.org/en/left_sidebar/people_view.html
- [DK8] Map search view. https://docs.digikam.org/en/left_sidebar/mapsearch_view.html
- [DK9] Image view: renaming (Advanced Rename). https://docs.digikam.org/en/main_window/image_view.html
- [DK10] Scan for new items. https://docs.digikam.org/en/maintenance_tools/maintenance_newitems.html
- [DK11] Miscellaneous settings. https://docs.digikam.org/en/setup_application/miscs_settings.html
- [DK12] Auto-tags assignment. https://docs.digikam.org/en/maintenance_tools/maintenance_autotags.html
- [DK13] digiKam 8.6.0 released (2025-03-15). https://www.digikam.org/news/2025-03-15-8.6.0_release_announcement/
- [DK14] digiKam 9.1.0 released (2026-06-07). https://www.digikam.org/news/2026-06-07-9.1.0_release_announcement/
- [DK15] Natural language search, GSoC 2026 (2026-08). https://www.digikam.org/news/2026-08-20-advanced_search_improvements_with_llm/
- [DK16] KDE Discuss, digiKam rescans for hours when started before the NAS (2025-03). https://discuss.kde.org/t/when-i-start-digikam-before-starting-the-nas-where-the-photos-are-stored-digikam-spends-hours-working-before-i-can-see-albums/31270
- [DK17] KDE Discuss, network share album keeps breaking (2025-04 to 2026-06). https://discuss.kde.org/t/digikam-keeps-messing-up-network-share-albumb/32561
- [DK18] KDE Discuss, duplicate search takes days (2024-09). https://discuss.kde.org/t/duplicate-search-takes-literally-days/21438
- [DK19] KDE Discuss, lazy sync (2025-12). https://discuss.kde.org/t/digikam-lazy-sync/42775
- [DK20] KDE Discuss, large-scale multi-user workflows (2025-09). https://discuss.kde.org/t/guidance-on-large-scale-multi-user-workflows-with-digikam/39657

**IMatch** (help for IMatch 2026; photools.com)

- [IM1] Meet IMatch. https://www.photools.com/help/imatch/index.php?name=app_intro.htm
- [IM2] Searching. https://www.photools.com/help/imatch/index.php?name=search_basics.htm
- [IM3] The File Window: search bar. https://www.photools.com/help/imatch/index.php?name=fw_basics.htm
- [IM4] Semantic search with AI. https://www.photools.com/help/imatch/index.php?name=semantic-search-with-ai.htm
- [IM5] Categories. https://www.photools.com/help/imatch/index.php?name=cat_basics.htm
- [IM6] AutoTagger. https://www.photools.com/help/imatch/index.php?name=auto-tagger.htm
- [IM7] Offline folders and files. https://www.photools.com/help/imatch/index.php?name=offline-files.htm
- [IM8] File management (Relocate, lifetime ID). https://www.photools.com/help/imatch/index.php?name=file_management.htm
- [IM9] Indexing files. https://www.photools.com/help/imatch/index.php?name=rmh_dlg_scanfolder.htm
- [IM10] Creating the database. https://www.photools.com/help/imatch/index.php?name=rmh_database_new.htm
- [IM11] Metadata write-back. https://www.photools.com/help/imatch/index.php?name=md_writeback.htm
- [IM12] IMatch performance tips for large photo libraries (2026-07-05). https://www.photools.com/11908/imatch-performance-tips-for-large-photo-libraries/
- [IM13] The Filter Panel. https://www.photools.com/help/imatch/index.php?name=panel_filter.htm

**Photo Supreme** (IDimager; manuals "version 11")

- [PS1] 20K, 160K, 700K: Photo Supreme at scale (vendor; tested with 2026.3.2). https://www.idimager.com/photo-supreme-blog-articles/20k-160k-700k-photo-supreme-at-scale
- [PS2] Why Photo Supreme has its own search layer. https://www.idimager.com/photo-supreme-design-articles/why-photo-supreme-has-its-own-search-engine
- [PS3] Frequently asked questions. https://www.idimager.com/frequently-asked-questions
- [PS4] Folder management. https://manualsu.idimager.com/version11/HTMLRoot/folder-file-management/folder-management.html
- [PS5] Folder verification. https://manualsu.idimager.com/version11/HTMLRoot/folder-file-management/folder-verification.html
- [PS6] Advanced search. https://manualsu.idimager.com/version11/HTMLRoot/searching/advanced-search.html
- [PS7] Dynamic Search Panel. https://manualsu.idimager.com/version11/HTMLRoot/searching/dynamic-search-panel.html
- [PS8] The search bar. https://manualsu.idimager.com/version11/HTMLRoot/searching/the-search-bar.html
- [PS9] Cross-platform folder mappings. https://manualsu.idimager.com/version11/HTMLRoot/folder-file-management/create-cross-platform-folder-mappings.html
- [PS10] Home page (testimonials). https://www.idimager.com/

**NeoFinder** (9.3.1; Users Guide)

- [NF1] Home page (version, testimonials). https://www.cdfinder.de/
- [NF2] Performance tuning. https://www.cdfinder.de/guide/11/performance.html
- [NF3] Faster finding. https://www.cdfinder.de/guide/11/11.2/fast-find.html
- [NF4] Update catalogs. https://www.cdfinder.de/guide/3/3.5/updating.html
- [NF5] AutoUpdater. https://www.cdfinder.de/guide/3/3.9/auto-updater.html
- [NF6] Reconnect catalog. https://www.cdfinder.de/guide/4/4.14/reconnect.html
- [NF7] The Find Editor. https://www.cdfinder.de/guide/5/5.2/findeditor.html
- [NF8] Find duplicates. https://www.cdfinder.de/guide/5/5.3/find_duplicates.html
- [NF9] Find similar photos. https://www.cdfinder.de/guide/5/5.8/find_similar_photos.html
- [NF10] Find faces. https://www.cdfinder.de/guide/5/5.9/find_faces.html
- [NF11] XMP editor. https://www.cdfinder.de/guide/13/13.1/neofinder_bridge.html
- [NF12] Multiple-user installation with a file server. https://www.cdfinder.de/guide/2/2.2/neofinder_server.html
- [NF13] FAQ. https://cdfinder.de/guide/25/faq.html

**Peakto and Excire**

- [PK1] Peakto updates (2.7, 2026-02-26, and earlier). https://cyme.io/en/products/peakto/updates/
- [PK2] Peakto product page (testimonials). https://cyme.io/en/products/peakto/
- [PK3] PetaPixel, Peakto Search plug-in for Lightroom (2024-03-26). https://petapixel.com/2024/03/26/find-any-photo-in-lightroom-with-the-ai-powered-peakto-search-plugin/
- [PK4] Peakto features. https://cyme.io/en/products/peakto/features/
- [EX1] Excire Foto 2027. https://excire.com/en/excire-foto/
- [EX2] Excire Foto 2027 is here (2026-06-15). https://excire.com/en/excire-foto-2027-is-here/
- [EX3] Excire Search 2026. https://excire.com/en/excire-search/
- [EX4] Excire Foto Office Edition. https://excire.com/en/excire-foto-office/
- [EX5] PetaPixel, Excire Search 2026 review (2026-01-11). https://petapixel.com/2026/01/11/excire-search-2026-lets-me-focus-on-the-photos-i-care-about-the-most/

**Apple Photos** (Photos User Guide for Photos 12 on macOS 27; support articles)

- [AP1] Change where photos and videos are stored. https://support.apple.com/en-gb/guide/photos/pht1ed9b966d/mac
- [AP2] Search for photos and videos. https://support.apple.com/en-gb/guide/photos/pht64de33e5a/mac
- [AP3] Find and name people and pets. https://support.apple.com/en-gb/guide/photos/phtad9d981ab/mac
- [AP4] Find photos and videos by location. https://support.apple.com/en-gb/guide/photos/pht4c00b8ddc/mac
- [AP5] Remove duplicates. https://support.apple.com/en-gb/guide/photos/pht5a3157c1d/mac
- [AP6] Create Smart Albums. https://support.apple.com/en-gb/guide/photos/pht6d60ca71/mac
- [AP7] Add keywords. https://support.apple.com/en-gb/guide/photos/pht8d0ad5198/mac
- [AP8] Move your Photos library to save space on your Mac (HT201517, now 108345). https://support.apple.com/en-gb/108345
- [AP9] Export photos, videos, slideshows and memories. https://support.apple.com/en-gb/guide/photos/pht6e157c5f/mac
- [AP10] Filter your photo library. https://support.apple.com/en-gb/guide/photos/pht5f5daeb1b/mac

**ACDSee, ON1 and DxO**

- [AC1] ACDSee Photo Studio for Mac 26. https://www.acdsee.com/en/products/photo-studio-mac/
- [AC2] ACDSee Photo Studio for Mac 26 features. https://www.acdsee.com/en/products/photo-studio-mac/features/
- [AC3] ACDSee digital asset management. https://www.acdsee.com/en/digital-asset-management/
- [OR1] ON1, Browse vs cataloged workflows in ON1 Photo RAW (2026-03-17, with comments). https://www.on1.com/blog/browse-vs-cataloged-workflows-in-on1-photo-raw/
- [OR2] ON1, Browsing vs cataloging (2016; comments 2018–2025). https://www.on1.com/blog/browsing-vs-cataloging-the-ins-and-outs/
- [OR3] ON1, Sneak peek: enhanced cataloging (2023-10-04). https://www.on1.com/blog/sneak-peek-enhanced-cataloging-of-photos/
- [OR4] ON1 Photo RAW features (2026; 2027 announced). https://www.on1.com/products/photo-raw/features/
- [OR5] ON1, Photo organization in 2025. https://www.on1.com/blog/photo-organization-in-2025-on1-photo-raw-vs-lightroom-classic-which-is-best-for-you/
- [DX1] DxO forum, Relocate folders that have been moved (2025-10 to 2026-02). https://forum.dxo.com/t/relocate-folders-that-have-been-moved/52238
- [DX2] DxO forum, Restore the archive and get a load of question marks (2026-02). https://forum.dxo.com/t/not-new-still-annoying-restore-the-archive-and-get-a-load-of-question-marks/54004
- [DX3] DxO forum, How do I move folders around without getting lost images (2025-03). https://forum.dxo.com/t/how-do-i-move-folders-around-without-getting-lost-images/49354
- [DX4] DxO forum, PL5: moving files outside PL loses corrections (2022-03). https://forum.dxo.com/t/pl5-moving-files-outside-pl-loses-corrections-and-more/25664
- [DX5] DxO forum, Most of my images aren't worth a 15-minute loading time (2025-10). https://forum.dxo.com/t/most-of-my-images-arent-worth-a-15-minute-loading-time/52236
- [DX6] DxO forum, PL7 slow start-up counting through all images in a folder (2023-09). https://forum.dxo.com/t/dxo-pl7-slow-startup-due-to-counting-through-all-images-in-a-folder/34892
- [DX7] DxO forum, V9 and XMP files (2026-08; quotes the PhotoLab 9 manual). https://forum.dxo.com/t/v9-and-xmp-files/55960
- [DX8] DxO forum, Automatically loading and saving sidecars (DxO staff, 2018-12). https://forum.dxo.com/t/automatically-loading-saving-sidecar-we-need-your-opinion/5816
- [DX9] DxO forum, 9.7.0: issue with projects and local edits (2026-04). https://forum.dxo.com/t/9-7-0-build-44-major-issue-with-projects-and-local-edits/54866
- [DX10] DxO forum, PhotoLibrary slow with more than 1,000 images in a folder (2021-07). https://forum.dxo.com/t/photolibrary-image-browser-gets-very-slow-with-more-than-1000-images-in-a-folder/20483

### Not reached

- **Refused (HTTP 403):** bugs.kde.org, invent.kde.org and community.kde.org (digiKam bug reports, source and GSoC report); www.dxo.com and support.dxo.com (DxO product pages, release notes and help); help.acdsystems.com (ACDSee help); on1help.zendesk.com (ON1 user guides); www.dpreview.com; the photools.com community search, which refuses guests.
- **Refused by the sandbox proxy (503 on connect):** documentation.on1.com, forum.on1.com and community.on1.com. help.dxo.com did not connect.
- **Behind a human check:** discussions.apple.com.
- **Rendered only with JavaScript, no content returned:** support.excire.com, learning-center.excire.com and desk.cyme.io.
- **Search engines:** html.duckduckgo.com returned a bot challenge (202) and bing.com returned unrelated results, so sources were found through each site's own search instead.
- docs.darktable.org answered normally on 2026-10-05.

[DT1]: https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/shared/collections/
[DT2]: https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/shared/collection-filters/
[DT3]: https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/shared/tagging/
[DT4]: https://docs.darktable.org/usermanual/5.6/en/overview/sidecar-files/sidecar/
[DT5]: https://docs.darktable.org/usermanual/5.6/en/overview/sidecar-files/sidecar-import/
[DT6]: https://docs.darktable.org/usermanual/5.6/en/preferences-settings/storage/
[DT7]: https://docs.darktable.org/usermanual/5.6/en/overview/sidecar-files/local-copies/
[DT8]: https://docs.darktable.org/usermanual/5.6/en/lighttable/digital-asset-management/thumbnails/
[DT9]: https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/lighttable/import/
[DT10]: https://docs.darktable.org/usermanual/5.6/en/lighttable/digital-asset-management/collections/
[DT11]: https://github.com/darktable-org/darktable/releases/tag/release-4.6.0
[DT12]: https://github.com/darktable-org/darktable/releases/tag/release-4.8.0
[DT13]: https://github.com/darktable-org/darktable/releases/tag/release-5.4.0
[DT14]: https://github.com/darktable-org/darktable/issues/21849
[DT15]: https://github.com/darktable-org/darktable/pull/21850
[DT16]: https://github.com/darktable-org/darktable/issues/17215
[DT17]: https://github.com/darktable-org/darktable/issues/21268
[DT18]: https://github.com/darktable-org/darktable/issues/19728
[DT19]: https://github.com/darktable-org/darktable/issues/18253
[DT20]: https://github.com/darktable-org/darktable/issues/18599
[DT21]: https://github.com/darktable-org/darktable/issues/16091
[DT22]: https://discuss.pixls.us/t/slow-image-import-to-a-large-library/22327
[DT23]: https://discuss.pixls.us/t/darktable-keeps-losing-my-files-forcing-a-re-import/41496
[DT24]: https://discuss.pixls.us/t/how-do-i-propose-a-change-to-export-function-to-add-images-to-library-upon-export/31518
[DK1]: https://docs.digikam.org/en/getting_started/database_intro.html
[DK2]: https://docs.digikam.org/en/setup_application/database_settings.html
[DK3]: https://docs.digikam.org/en/setup_application/collections_settings.html
[DK4]: https://docs.digikam.org/en/setup_application/metadata_settings.html
[DK5]: https://docs.digikam.org/en/left_sidebar/search_view.html
[DK6]: https://docs.digikam.org/en/left_sidebar/similarity_view.html
[DK7]: https://docs.digikam.org/en/left_sidebar/people_view.html
[DK8]: https://docs.digikam.org/en/left_sidebar/mapsearch_view.html
[DK9]: https://docs.digikam.org/en/main_window/image_view.html
[DK10]: https://docs.digikam.org/en/maintenance_tools/maintenance_newitems.html
[DK11]: https://docs.digikam.org/en/setup_application/miscs_settings.html
[DK12]: https://docs.digikam.org/en/maintenance_tools/maintenance_autotags.html
[DK13]: https://www.digikam.org/news/2025-03-15-8.6.0_release_announcement/
[DK14]: https://www.digikam.org/news/2026-06-07-9.1.0_release_announcement/
[DK15]: https://www.digikam.org/news/2026-08-20-advanced_search_improvements_with_llm/
[DK16]: https://discuss.kde.org/t/when-i-start-digikam-before-starting-the-nas-where-the-photos-are-stored-digikam-spends-hours-working-before-i-can-see-albums/31270
[DK17]: https://discuss.kde.org/t/digikam-keeps-messing-up-network-share-albumb/32561
[DK18]: https://discuss.kde.org/t/duplicate-search-takes-literally-days/21438
[DK19]: https://discuss.kde.org/t/digikam-lazy-sync/42775
[DK20]: https://discuss.kde.org/t/guidance-on-large-scale-multi-user-workflows-with-digikam/39657
[IM1]: https://www.photools.com/help/imatch/index.php?name=app_intro.htm
[IM2]: https://www.photools.com/help/imatch/index.php?name=search_basics.htm
[IM3]: https://www.photools.com/help/imatch/index.php?name=fw_basics.htm
[IM4]: https://www.photools.com/help/imatch/index.php?name=semantic-search-with-ai.htm
[IM5]: https://www.photools.com/help/imatch/index.php?name=cat_basics.htm
[IM6]: https://www.photools.com/help/imatch/index.php?name=auto-tagger.htm
[IM7]: https://www.photools.com/help/imatch/index.php?name=offline-files.htm
[IM8]: https://www.photools.com/help/imatch/index.php?name=file_management.htm
[IM9]: https://www.photools.com/help/imatch/index.php?name=rmh_dlg_scanfolder.htm
[IM10]: https://www.photools.com/help/imatch/index.php?name=rmh_database_new.htm
[IM11]: https://www.photools.com/help/imatch/index.php?name=md_writeback.htm
[IM12]: https://www.photools.com/11908/imatch-performance-tips-for-large-photo-libraries/
[IM13]: https://www.photools.com/help/imatch/index.php?name=panel_filter.htm
[PS1]: https://www.idimager.com/photo-supreme-blog-articles/20k-160k-700k-photo-supreme-at-scale
[PS2]: https://www.idimager.com/photo-supreme-design-articles/why-photo-supreme-has-its-own-search-engine
[PS3]: https://www.idimager.com/frequently-asked-questions
[PS4]: https://manualsu.idimager.com/version11/HTMLRoot/folder-file-management/folder-management.html
[PS5]: https://manualsu.idimager.com/version11/HTMLRoot/folder-file-management/folder-verification.html
[PS6]: https://manualsu.idimager.com/version11/HTMLRoot/searching/advanced-search.html
[PS7]: https://manualsu.idimager.com/version11/HTMLRoot/searching/dynamic-search-panel.html
[PS8]: https://manualsu.idimager.com/version11/HTMLRoot/searching/the-search-bar.html
[PS9]: https://manualsu.idimager.com/version11/HTMLRoot/folder-file-management/create-cross-platform-folder-mappings.html
[PS10]: https://www.idimager.com/
[NF1]: https://www.cdfinder.de/
[NF2]: https://www.cdfinder.de/guide/11/performance.html
[NF3]: https://www.cdfinder.de/guide/11/11.2/fast-find.html
[NF4]: https://www.cdfinder.de/guide/3/3.5/updating.html
[NF5]: https://www.cdfinder.de/guide/3/3.9/auto-updater.html
[NF6]: https://www.cdfinder.de/guide/4/4.14/reconnect.html
[NF7]: https://www.cdfinder.de/guide/5/5.2/findeditor.html
[NF8]: https://www.cdfinder.de/guide/5/5.3/find_duplicates.html
[NF9]: https://www.cdfinder.de/guide/5/5.8/find_similar_photos.html
[NF10]: https://www.cdfinder.de/guide/5/5.9/find_faces.html
[NF11]: https://www.cdfinder.de/guide/13/13.1/neofinder_bridge.html
[NF12]: https://www.cdfinder.de/guide/2/2.2/neofinder_server.html
[NF13]: https://cdfinder.de/guide/25/faq.html
[PK1]: https://cyme.io/en/products/peakto/updates/
[PK2]: https://cyme.io/en/products/peakto/
[PK3]: https://petapixel.com/2024/03/26/find-any-photo-in-lightroom-with-the-ai-powered-peakto-search-plugin/
[PK4]: https://cyme.io/en/products/peakto/features/
[EX1]: https://excire.com/en/excire-foto/
[EX2]: https://excire.com/en/excire-foto-2027-is-here/
[EX3]: https://excire.com/en/excire-search/
[EX4]: https://excire.com/en/excire-foto-office/
[EX5]: https://petapixel.com/2026/01/11/excire-search-2026-lets-me-focus-on-the-photos-i-care-about-the-most/
[AP1]: https://support.apple.com/en-gb/guide/photos/pht1ed9b966d/mac
[AP2]: https://support.apple.com/en-gb/guide/photos/pht64de33e5a/mac
[AP3]: https://support.apple.com/en-gb/guide/photos/phtad9d981ab/mac
[AP4]: https://support.apple.com/en-gb/guide/photos/pht4c00b8ddc/mac
[AP5]: https://support.apple.com/en-gb/guide/photos/pht5a3157c1d/mac
[AP6]: https://support.apple.com/en-gb/guide/photos/pht6d60ca71/mac
[AP7]: https://support.apple.com/en-gb/guide/photos/pht8d0ad5198/mac
[AP8]: https://support.apple.com/en-gb/108345
[AP9]: https://support.apple.com/en-gb/guide/photos/pht6e157c5f/mac
[AP10]: https://support.apple.com/en-gb/guide/photos/pht5f5daeb1b/mac
[AC1]: https://www.acdsee.com/en/products/photo-studio-mac/
[AC2]: https://www.acdsee.com/en/products/photo-studio-mac/features/
[AC3]: https://www.acdsee.com/en/digital-asset-management/
[OR1]: https://www.on1.com/blog/browse-vs-cataloged-workflows-in-on1-photo-raw/
[OR2]: https://www.on1.com/blog/browsing-vs-cataloging-the-ins-and-outs/
[OR3]: https://www.on1.com/blog/sneak-peek-enhanced-cataloging-of-photos/
[OR4]: https://www.on1.com/products/photo-raw/features/
[OR5]: https://www.on1.com/blog/photo-organization-in-2025-on1-photo-raw-vs-lightroom-classic-which-is-best-for-you/
[DX1]: https://forum.dxo.com/t/relocate-folders-that-have-been-moved/52238
[DX2]: https://forum.dxo.com/t/not-new-still-annoying-restore-the-archive-and-get-a-load-of-question-marks/54004
[DX3]: https://forum.dxo.com/t/how-do-i-move-folders-around-without-getting-lost-images/49354
[DX4]: https://forum.dxo.com/t/pl5-moving-files-outside-pl-loses-corrections-and-more/25664
[DX5]: https://forum.dxo.com/t/most-of-my-images-arent-worth-a-15-minute-loading-time/52236
[DX6]: https://forum.dxo.com/t/dxo-pl7-slow-startup-due-to-counting-through-all-images-in-a-folder/34892
[DX7]: https://forum.dxo.com/t/v9-and-xmp-files/55960
[DX8]: https://forum.dxo.com/t/automatically-loading-saving-sidecar-we-need-your-opinion/5816
[DX9]: https://forum.dxo.com/t/9-7-0-build-44-major-issue-with-projects-and-local-edits/54866
[DX10]: https://forum.dxo.com/t/photolibrary-image-browser-gets-very-slow-with-more-than-1000-images-in-a-folder/20483
