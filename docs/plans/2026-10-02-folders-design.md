# Folders working set: design

The owner's requests (2 October 2026):

1. Bring back Lightroom Classic's folder navigation: the sidebar holds several folders the user added, a working set rather than a catalog.
2. "This absolutely cannot impact performance": the app stays responsive whatever the number of photos, and memory stays in check.
3. Use the whole machine (every core, fast I/O, the GPU where it wins) so Redlamp is instant and best in class.
4. The filmstrip follows changes on disk by itself.

Answers that fixed the scope: one folder at a time in the filmstrip, with "Show Photos in Subfolders"; read-only (nothing on disk changes); missing folders are flagged.

Until now Redlamp had one folder at a time, opened with ⌘O and remembered as `lastFolder`. Opening it read every photo's sidecar, coordinated and with its mask PNGs, one after another, before showing anything; the filmstrip was a SwiftUI `LazyHStack` whose cells all re-rendered whenever any thumbnail arrived, and thumbnails were kept forever.

## What users get

- **A Folders panel**, first in the scrolling column under the Navigator, collapsible like the others.
  - The header's **+** (Add Folder…), File › Open (⌘O) and dropping folders on the window add folders. Opening or dropping files adds their folder and selects them.
  - Each folder you added is a root that expands into its subfolders. Every row shows how many photos are directly in it.
  - Clicking a row opens that folder in the filmstrip. The open folder is highlighted.
  - The context menu: Show in Finder, Show Photos in Subfolders, Remove from Folders (roots only) and Locate… (missing roots).
- **One folder at a time in the filmstrip.** With Show Photos in Subfolders (View menu, or the panel's context menu) it shows everything beneath the folder, ordered by subfolder, then name. The header shows the folder's name and the total.
- **Read-only.** Nothing on disk is created, renamed or moved.
- **Live.** Photos added to the open folder (or beneath it, with subfolders on) slide into place, deleted ones leave, a rename moves, and the scroll position stays. The selected photo stays selected; if it goes, its neighbour is selected. A shoot being copied in arrives as a few batches, and a photo still being written shows a placeholder until its size settles. A file overwritten in place gets a new thumbnail. Sidecars changed elsewhere refresh their badges. Folder counts follow.
- **Missing folders.** A root that is missing or on an unmounted volume is dimmed with a "?" badge; if it was open, the filmstrip says so, and it fills again when the volume comes back.
- **Remembered:** the roots (as bookmarks, so a renamed or moved folder is followed), the open folder, the subfolders option, the expanded rows and the last photo in each folder. `lastFolder` becomes the first root.

## Performance contract

Every rule below is enforced by a test or by `--folders-perf` (see Verification).

- **No file I/O on the main thread**: listing, sidecar summaries, bookmark resolution (a network volume can block), and the sidecar read when a photo is selected (`select()` read it on the main thread when the photo was already decoded).
- **Listing reads no sidecars.** One directory listing, with the resource keys asked for up front, gives the photos, their sizes and dates, their iCloud state and which of them have a `.redlamp` package. Photos without one need nothing more.
- **Badges come from a light probe** of `edit.json`: the recipe and the metadata only, no mask PNGs, history or conflict resolution. Probes run in parallel, visible photos first, and are dropped when the folder changes. Conflicts are still resolved when a photo is opened.
- **Streaming.** The open folder's photos appear as soon as its listing returns. With subfolders on, the subfolders are listed in parallel and arrive in order, so nothing sorts 50,000 names at once.
- **O(1) lookups.** A URL-to-index map serves `select`, stepping, the prefetch working set, saving and ratings.
- **Bounded thumbnails.**
  - In memory: an LRU of decoded thumbnails with a 128 MB budget (about 1,200 at 192 × 140), trimmed to what's visible on a memory-pressure warning. They're always decoded from their pack JPEG, whose pixels ImageIO keeps in purgeable memory: the system can take it back, and it doesn't count against Redlamp, so a full LRU costs about 45 MB of footprint.
  - Decoded at the cell's pixel size (192 px), not 256.
  - On disk: one pack file per folder in `~/Library/Caches/app.redlamp/Thumbnails`, at most 1 GB across packs (about 100,000 thumbnails), least recently used packs first to go.
  - Files iCloud hasn't downloaded are never read: they show a cloud.
- **Per-cell updates.** A thumbnail or badge arriving touches only its own cell.
- **Budgets** (an M-series Pro's internal SSD):

| | Target |
| --- | --- |
| Main thread, while opening folders, streaming, scrolling and warming | p99 under 8.3 ms |
| First photos in the filmstrip | under 50 ms |
| A 50,000-photo tree in 500 folders, fully listed | under 300 ms |
| Visible thumbnails | under 150 ms from the pack, under 400 ms from the files |
| Background warming | at least 300 thumbnails a second from the files, 2,000 from the pack |
| Memory | see Memory budgets |

## Memory budgets

The footprint (`phys_footprint`, which Activity Monitor shows as Memory) is what macOS charges Redlamp for and what memory pressure acts on, so the budgets are footprints. They're counted over the footprint at launch: the engine's Metal setup and the frameworks (about 150 MB) aren't the folders' to spend. `--folders-perf` checks them on 50,000 photos in 500 folders, through each phase of browsing:

| Over the footprint at launch | Budget | Measured |
| --- | --- | --- |
| The peak, while listing, decoding, warming, reading the pack and scrolling | under 200 MB | 163 to 168 MB |
| Once listed | under 1.2 KB a photo (57 MB) | 43 to 52 MB |
| Browsing paused, without memory pressure | under 180 MB | 155 to 162 MB |
| After a memory-pressure trim | under 80 MB | 52 to 54 MB |
| Idle after the trim | under 80 MB | 54 to 58 MB |

And for the parts:

- **Thumbnails in memory:** at most 128 MB of pixels, the LRU's budget. Each costs about 33 KB of footprint (ImageIO's state and the JPEG); its 96 KB of pixels are purgeable. A full LRU is about 45 MB.
- **Decodes in flight:** no more than the lanes are wide together (32 on an M1 Ultra). Each is a LibRaw instance (750 KB) and ImageIO's decode of the preview, read where it is in the file's mapping, whose clean pages don't count.
- **Stack detection:** one batch of frames at a time (one frame, on the background lane), never a whole run.
- **Photos:** about 0.9 KB each over launch once listed, 0.7 KB of it live. Most of that is the URL each keeps (512 B); the item is about 100 B and its index entry 63 B. The 150 B a photo first planned assumed names, not URLs. A name per photo and a URL per folder is the next saving.

`--folders-perf` ends its report with PASS or FAIL for each budget and for the performance contract, and quits with status 1 when one fails; `scripts/folders-perf.sh` runs it on a Release build and fails with it. Unit tests hold the parts to theirs: the loader never holds more than its budget, whichever lanes ask; no more decodes run at once than the lanes allow; a raw's preview is decoded in place in the mapping, never copied; what a job autoreleases goes when the job ends; the focus signature stops at the first frame that doesn't match.

### Where the memory goes

`--folders-perf-memory` breaks the footprint down after each phase, and near each phase's peak, into `/tmp/redlamp-memory.txt`. It uses in-process APIs only, since `vmmap`, `footprint`, `heap` and `leaks` may not be allowed to run where Redlamp is measured:

- the kernel's ledgers (`task_info(TASK_VM_INFO)`): the footprint and its lifetime peak; anonymous memory, resident and compressed; GPU memory (the graphics ledger); purgeable memory, volatile and not; reusable pages;
- every VM region's dirty and compressed pages (`mach_vm_region_recurse`), grouped by the tag its allocator gave it: malloc's kinds, ImageIO, CoreGraphics, Core Animation, IOKit, IOSurface and IOAccelerator, stacks, mapped files and the shared cache;
- malloc's zones (`malloc_zone_statistics`): the bytes in live blocks, against its regions' pages;
- Redlamp's own counts: photos, thumbnails in memory, packs open, and jobs running in each lane.

It can't say which code owns a malloc block (that takes MallocStackLogging and `heap`), nor split up GPU memory that isn't mapped into the process. That memory, page tables and IOKit's own are left as "not in a region".

On macOS 26, malloc keeps the blocks it frees, of every size, for reuse, and they stay in the footprint. Of 16 MB freed in 1 MB blocks, all 16 are still counted, and `malloc_zone_pressure_relief` gives nothing back (in a test program, the undocumented `MallocSpaceEfficient=1` and `MallocLargeCache=0` do). So the footprint follows the highest amount ever allocated at once, transient buffers included, and doesn't come down by itself. The budgets therefore hold down transient memory as much as what is kept.

## Using the hardware

Redlamp feels instant because it uses the whole machine, not because it does little.

- **`WorkScheduler`** (RedlampDocument) runs every bulk job: listings, probes, thumbnail decodes, warming and stack detection. It has three lanes:
  - **on-screen**, at user-initiated priority, as wide as the performance cores (`hw.perflevel0.logicalcpu`);
  - **look-ahead**, at utility priority, half as wide;
  - **background**, at utility priority, half as wide as the performance cores (at least as wide as the efficiency cores, `hw.perflevel1.logicalcpu`). It was background priority at first; see Results.

  Jobs run on GCD threads (blocking I/O doesn't belong on Swift's cooperative pool), each in an autorelease pool of its own: GCD's global queues drain theirs only when a thread runs out of work, so what the frameworks autorelease would outlive the job for as long as the lanes stay busy. A queued job is promoted when it becomes visible, and a job whose folder or cell went away is dropped before it starts. Background jobs start only while no on-screen job waits, and not at all in Low Power Mode or when the Mac is hot (`thermalState` serious or critical), as exports already rest.
- **I/O in parallel.** With subfolders on, each folder is listed by its own job. Probes read `edit.json` without file coordination, which is safe because it is always written atomically (directly, or by replacing the whole package), and skip sidecars iCloud hasn't downloaded. Probes run on the look-ahead lane in batches of 32 rows, the visible rows' batches promoted to on screen: decoding the JSON, not reading it, is most of their cost.
- **Decoding where it's cheapest.** A raw file's thumbnail comes from the smallest embedded JPEG preview that's big enough (found by LibRaw), decoded at reduced scale by ImageIO where it is in the file's mapping, without copying it out; HEIC uses the hardware decoder. Both run on all performance cores at once. Stack detection's blur, correlation and sharpness use Accelerate (vDSP). Core Animation composites the filmstrip on the GPU, so scrolling never redraws a thumbnail.
- **Raw files without a usable preview** (rare: some DNGs) are the expensive case. The trial compares ImageIO's full decode with a reduced-size develop in the engine; see Results.
- **Warming.** While nothing is waiting on screen, thumbnails for the rest of the open folder, then for its sibling folders, are decoded into the pack on the background lane, so scrolling never waits. Warmed thumbnails go to the pack, not to memory.

## Components

```mermaid
flowchart LR
  subgraph document [RedlampDocument]
    WorkScheduler
    FolderScanner["FolderScanner: listing and ordered walk"]
    SidecarProbe["SidecarStore.summary: the light probe"]
    ThumbnailPacks["ThumbnailPacks: per-folder pack files"]
    FolderWatcher["FolderWatcher: FSEvents"]
  end
  subgraph ui [RedlampUI]
    FolderLibrary["FolderLibrary: roots, tree, open folder, items"]
    ThumbnailLoader["ThumbnailLoader: LRU, packs, warming"]
    FoldersPanel["Folders panel"]
    Filmstrip["Filmstrip: NSCollectionView"]
    EditorModel
  end
  FolderScanner --> FolderLibrary
  SidecarProbe --> FolderLibrary
  FolderWatcher --> FolderLibrary
  ThumbnailPacks --> ThumbnailLoader
  FolderLibrary --> FoldersPanel
  FolderLibrary --> Filmstrip
  ThumbnailLoader --> Filmstrip
  FolderLibrary --> EditorModel
  WorkScheduler -.-> FolderScanner
  WorkScheduler -.-> SidecarProbe
  WorkScheduler -.-> ThumbnailLoader
```

- **`FolderLibrary`** (`@MainActor @Observable`, `model.library`) owns the roots, the lazily listed tree, the open folder, the subfolders option, the photos (`items`) with their index map, and the last photo per folder. `items` changes are published as diffs (inserted, removed, moved and updated rows) to the filmstrip, so a badge or a new file never reloads the strip. Views observe only `count` and `openFolder`, never the array, so a probe result doesn't re-render SwiftUI.
- **`EditorModel`** keeps the open photo's metadata itself, read from its sidecar when it opens, and saves that, not a lookup in `items`. A selection that isn't in `items` (a photo opened from elsewhere) no longer saves empty ratings.
- **Bookmarks.** A root is stored as bookmark data with its last known path, behind `FolderAccess`, which calls `startAccessingSecurityScopedResource`. That does nothing until the app is sandboxed, so the Mac App Store sandbox needs no model change.
- **Tree.** A row is listed the first time it is visible. That one listing gives its count and its subfolders, so expanding is instant. Packages (sidecars, `.photoslibrary`, apps) and hidden folders are not folders here.
- **`FolderWatcher`** is one FSEvents stream over all roots, with a 0.3 s latency. Only listed directories (the open folder, its subtree with subfolders on, visible tree rows) are listed again, and the result is diffed into what's shown. A new subfolder under an open subtree is walked and merged in. A file whose size or date is still changing waits for 2 s of quiet before its thumbnail is requested. Mounts and unmounts (NSWorkspace) drive the missing state. Network volumes have no FSEvents, so their listed folders are polled every 15 s.
- **Stack detection** runs per directory on the background lane, one directory at a time, and its result is cached per directory by the listing's names, sizes and dates, so opening a folder again doesn't read every photo's EXIF. A run's frames are scored in order as they're read: each is compared, blurred, with the frame before, then kept only as its 24 cells' sharpness. So detection holds one thumbnail rather than the run's (35 MB for 100 frames), and stops reading a run at the first frame that doesn't match.

## Thumbnail packs

A pack is one file per folder, named by a hash of the folder's path. It starts with a header (`RLTP`, version 1) and is then a sequence of records, each a photo's name, size, modification date and a JPEG (quality 0.8, about 10 KB at 192 px).

- **Reading:** the pack is mapped into memory once and its records indexed by name; the last record for a name wins. A record is used only if its size and date match the listing's, so an overwritten file is decoded again.
- **Writing:** new records are appended under the pack's lock. Earlier records for the same name become stale.
- **Compaction:** when more than a third of a pack is stale, it is rewritten with only its live records and swapped in atomically.
- **Eviction:** when the packs pass 1 GB, the least recently opened packs go first.

The JPEG decode happens into the memory LRU, in parallel on the scheduler, so the pack's pages stay clean and the OS can reclaim them without counting them as Redlamp's memory.

## The filmstrip

An AppKit `NSCollectionView` (horizontal flow) inside the existing floating pane. The header (folder, count, stack banner, file info) stays SwiftUI. Cells are layer-backed: the thumbnail is a layer's contents, and badges (edited, flag, stars, label, stack, cloud) are small layers set only when they change. Cells are reused. The collection view's prefetch callbacks queue look-ahead thumbnails and cancel them again; a cell scrolling into view promotes its thumbnail to on-screen. Changing the selection scrolls it to the centre.

## Persistence

`UserDefaults`, written when something changes:

| Key | Holds |
| --- | --- |
| `folders.roots` | The roots: bookmark data and last known path |
| `folders.open` | The open folder's path |
| `folders.subfolders` | Show Photos in Subfolders |
| `folders.expanded` | Expanded rows' paths |
| `folders.lastPhotos` | The last photo per folder (name), the 200 most recent folders |

`lastFolder` is read once, when `folders.roots` doesn't exist yet.

## Verification

- **Tests:** the scheduler (lanes, widths, promotion, cancellation, background pausing, a pool per job), the scanner (sidecars, packages, hidden files, iCloud state, ordered walk), the probe, packs (append, reopen, stale records, compaction, eviction), the library (streaming, diffs, index map, persistence, migration, missing roots), the watcher (files added, removed, renamed and rewritten in a temporary tree), the filmstrip's cell reuse and per-cell updates, the Folders panel, and the memory budgets' parts (see Memory budgets).
- **`scripts/make-folder-fixture.sh`** builds a tree of 50,000 photos in 500 folders as APFS clones of one sample, which uses no disk space.
- **`--folders-perf <folder>`** opens the tree, measures time to first items, full listing, first thumbnails, warming throughput from the files and from the pack, how busy the performance and efficiency cores were (`host_processor_info`), and main-thread statistics while scrolling the strip end to end. It follows the footprint every 5 ms through each phase, then waits with browsing paused, trims as a memory-pressure warning does, and idles. It writes `/tmp/redlamp-perf.txt`, ending with PASS or FAIL for every budget. `--folders-perf-memory` adds the breakdown (see Memory budgets); its region walks take a core, so performance is measured without it. `scripts/folders-perf.sh [folder] [flags]` runs it all on a Release build and exits 1 when a budget fails.
- **Harness:** the Folders scene shows the panel and the filmstrip on the fixture.

## Results

Measured with `--folders-perf` on 50,000 photos in 500 folders (APFS clones of one 24 MP ARW), on an M1 Ultra (16 performance and 4 efficiency cores), Release build. The Mac was busy throughout (load average 17 to 30: Spotlight, endpoint security, another build), so these are conservative.

| | Target | Measured |
| --- | --- | --- |
| First photos (subfolders on) | under 50 ms | 13.7 ms |
| All 50,000 photos listed | under 300 ms | 209 ms |
| Visible thumbnails (15, from the files) | under 400 ms | 33 ms (197 ms through ImageIO) |
| Warming from the files | at least 300 a second | 705 a second (253 through ImageIO) |
| From the pack | at least 2,000 a second | 6,210 a second |
| Main thread while listing, decoding, warming | p99 under 8.3 ms | p99 0.15 ms, max 12 ms |
| Main thread scrolling the strip end to end in 4 s | p99 under 8.3 ms | p99 1.4 ms, max 22 ms |
| Memory | see Memory budgets | 317 MB peak against 152 MB before opening (531 MB before the memory work below); 207 MB idle after a memory-pressure trim |

What the measurements changed:

- **Listing.** The first scanner took 1.4 s for 10,000 photos. Asking every file for iCloud Drive's download state cost ten times the rest of the listing, and sorting compared URLs' last path components on every comparison. The scanner now asks for download state only in a folder iCloud Drive syncs, and sorts native names once: 120 ms for 10,000. Calling `getattrlistbulk` directly wasn't needed.
- **Warming at utility priority.** At background priority macOS throttles a thread's reads behind every other reader. With Spotlight indexing, warming fell to 4 thumbnails a second, against 224 at utility priority for the same decodes (and 127 on the on-screen lane). Warming now runs at utility priority, half as wide as the performance cores. It still waits while anything on screen does, and pauses in Low Power Mode and when the Mac is hot.
- **Stack detection** decoded 256 px thumbnails for every candidate run across every core, from the look-ahead lane. On the fixture, where every folder looks like a run, it starved warming and took memory to 1.7 GB. It now runs on the background lane one directory at a time, single-threaded, so it never holds more than one core.
- **The Folders panel** first rebuilt every row on each change: 64 ms per reload with 5,000 subfolders. Its rows now come from the tree on demand, one node per folder, and a listing reloads only its own row. Only rows on screen get views (under 60 for 5,000) and only folders on screen are listed.
- **Raw files without a preview.** Every fixture has an embedded preview, decoded through ImageIO in 6 to 30 ms on one core. A full ImageIO decode, which a previewless file needs, takes 64 to 206 ms, and the engine's own open is 70 to 250 ms. LibRaw's unpacking dominates both, so a reduced-size develop in the engine has no room to win; ImageIO stays.
- **Thumbnails from the smallest preview.** ImageIO decodes a raw's largest embedded JPEG (often full size) even for a 192 px thumbnail: about 25 ms each. Raw thumbnails now come from the smallest JPEG preview of at least 192 px in LibRaw's thumbnail list, read from one memory mapping of the file and turned upright by the preview's own orientation or LibRaw's. Per file that's 3 times faster for Sony and Pixel DNG files, 6 for Canon, 11 for Nikon and 1.6 for DNGs with only a full-size preview; Fujifilm files, with only a full-size preview, are level (`research/prototypes/thumbnails`). In the app, visible thumbnails went from 197 to 33 ms and warming from 253 to 705 a second.
- **A race in the packs.** With decodes this fast, many threads stored a new folder's first thumbnails at once; two could open its pack together, and one reset the new file while the other read its mapping (a bus error). A pack is now opened under the store's lock, and a new or unreadable pack file is replaced by renaming a fresh one over it, never truncated.
- **Memory.** The peak was 531 MB against 155 MB before opening, with 115 MB of thumbnails; `--folders-perf-memory` found where the rest went. At the peak, 201 MB was malloc's, freed and kept for reuse (the 27 MB at launch had grown by 174 MB, none of it ever returned). Another 145 MB were thumbnail bitmaps, 20 MB more than the LRU counted: thumbnails it had dropped, still held by worker threads' autorelease pools. The live heap had grown by 45 MB (the photos, and ImageIO's state for thumbnails from the pack). Breakdowns at launch, at the peak and idle after a trim (load average about 35):

  | MB | Launch | Before: peak | Before: idle | After: peak | After: idle |
  | --- | --- | --- | --- | --- | --- |
  | Footprint | 152 | 524 | 386 | 312 | 209 |
  | malloc, live blocks | 67 | 112 | 110 | 163 | 112 |
  | malloc, freed and held for reuse | 27 | 201 | 211 | 73 | 39 |
  | Thumbnail bitmaps (CoreGraphics) | 1 | 145 | 3 | 3 | 1 |
  | GPU (IOKit, IOSurface, IOAccelerator) and Core Animation | 40 | 41 | 41 | 40 | 41 |
  | The rest: stacks, mapped files, page tables | 17 | 25 | 21 | 33 | 16 |
  | Not counted: thumbnail pixels in ImageIO's purgeable memory | 0 | 0 | 0 | 122 | 2 |

  Each change below was measured with the others in place and taken out again (two or three runs each, load average 15 to 30):
  - **Previews decoded in place.** A raw's preview (1.1 MB for the Sony fixture, up to 5 MB for DNGs) was copied out of the file's mapping for ImageIO. With up to 24 decodes at once while scrolling, the copies' high-water mark stayed in the footprint. ImageIO now reads the preview in the mapping: peak 381 to 322 MB. A probe on its own: 16 threads decoding left 46 MB behind, against 15 MB without the copy.
  - **Thumbnails in purgeable memory.** A thumbnail decoded from the raw file is a 96 KB CoreGraphics bitmap that counts in full. One decoded from its pack JPEG is held by ImageIO in purgeable memory, which doesn't count (the system may take it back, and ImageIO decodes it again when drawn), for about 33 KB of state. The loader now keeps the decode of the JPEG it has just written to the pack, an extra decode of a fraction of a millisecond off the main thread: peak 410 to 322 MB, browsing paused 359 to 315 MB.
  - **An autorelease pool per job.** In half the runs the footprint stayed 100 to 130 MB higher after browsing, the thumbnail bitmaps the LRU had dropped still held in worker threads' pools. With a pool per job, idle after the trim went from 260, 393 and 383 MB to 278, 250 and 270 (before the other changes). With thumbnails purgeable it's within noise in short runs, and was 17 MB lower at the peak in a run warming 20,000.
  - **Stack detection streamed.** On the fixture every folder is a candidate run of 100 frames, whose float thumbnails were held together (35 MB). They're now scored as they're read: peak 346 to 322 MB, idle 233 to 213 MB.
  - **Rejected:**
    - Reading pack JPEGs in place too (saving the 8 KB copy a pack-decoded thumbnail keeps): no measurable change.
    - A cap of 8, 12 or 16 raw decodes at once, whatever the lane: 4 to 28 MB lower at the peak, but any cap below the lanes' total lets warming hold every slot while visible thumbnails wait, which the measurement doesn't cover.
    - A 64 MB LRU: about 45 MB lower in the one clean run, at the cost of half the thumbnails kept for scrolling back.
    - Reusing a LibRaw instance per thread: no change once previews weren't copied, in a probe; their 750 KB stay for good instead.
    - `malloc_zone_pressure_relief` after bursts: it gives back nothing on macOS 26.
  - **Performance didn't move.** Load average 15 to 19, three runs each, before and after: first photos 10 to 17 and 12 to 16 ms; 50,000 listed in 210 to 244 and 173 to 200 ms; visible thumbnails 19 to 24 and 17 to 25 ms; warming 657 to 717 and 682 to 705 a second; the pack 6,198 to 7,362 and 5,878 to 6,365 a second. Main-thread p99 was 0.2 ms both times while listing and warming, and 1.3 and 1.2 ms while scrolling.

## Later

Moving and renaming on disk, several folders in the filmstrip at once, a catalog, thumbnails that show the edit, collections, and a Library grid.
