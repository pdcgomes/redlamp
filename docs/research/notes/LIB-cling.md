# Cling, against the library's search

Cling is a fuzzy file finder for the Mac from lowtechguys.com: it indexes the names of the files on the Mac's disks and external drives, and finds one as you type, to act on it at once ([CL1]). Its source is on GitHub as FuzzyIdeas/Cling under GPL-3.0. Its README claims searches across more than 9 million files in under 100 ms, and 60 to 100 MB of memory with 1.6 million files indexed. This note reads its source at e55f4f3 (6 October 2026, a few commits past 3.0.0; the typo pass is one of them, so it may not be in a released build yet) against the library's index, query engine and change tracking on library/catalog (ca84cea), for what the library's search could take from it. The candidates are measured on this Mac with a benchmark of our own, `research/prototypes/library_search/`. Cling wasn't run; its own figures are its README's and its comments'.

Cling is GPL-3.0, and Redlamp ships under MPL-2.0 for the App Store (AGENTS.md, SKIP-08), so nothing here copies its code. Its techniques are described in our own words; the matching measured is written from fzf's published algorithm ([FZF], MIT) and Hyyrö's bit-parallel LCS ([HY04]).

## Summary

- **The library's search is already faster than Cling's where they overlap.** Cling scores every candidate path with fzf's algorithm across all cores; the library compiles a query to bitsets over its column store and answers the first page and count in p95 2.5 ms at a million photos (LIB-06). Cling's engine isn't a replacement for LIB-06, and its 150 ms wait after each keystroke would break the filter bar's 16 ms budget.
- **What's worth taking is around the search.** Four ideas, each measured here:
  - **Names folded to bytes once** ([section 3](#3-names-folded-to-bytes-once-lib-06)), LIB-06's open point on text that isn't ASCII: a keystroke over the fixture's 5,604 folder paths goes from p50 38 ms and p95 172 to 175 ms to p50 0.27 ms and p95 0.34 ms, with the same answer for every pair but one edge, `stras` against `Straße` before the second `s` is typed. Built on library/catalog since (e316f57), ignoring case only.
  - **The column store mapped from a file**, as Cling maps its index ([section 4](#4-the-column-store-mapped-from-a-file-lib-05-lib-06)): at a million photos, columns of 87 bytes a photo add 0.0 MB to the app's memory mapped, against 74 MB held in arrays, and map in under a millisecond; today they're built from SQLite at each launch, in 459 to 634 ms.
  - **Short text, fuzzy matching and typos** ([section 5](#5-short-text-fuzzy-matching-and-typos-lib-06-lib-18-lib-19)): free text under three characters is dropped today, small tables and all, so `z8`, `R5` and `東京` find every photo. Matched against the small tables, they find the camera or the folder. Fuzzy matching with typos, on rules like Cling's, over 8,673 names costs p95 1.6 to 1.7 ms a keystroke on one thread.
  - **Busy folders left out of change tracking** ([section 6](#6-busy-folders-under-a-root-lib-08)): a package written ten times a second under a watched root gives 3.4 FSEvents batches a second, each of which, by the library's code, becomes an indexer run and index writes while the user does nothing; with the package left out of the stream, none.
- **Found on the way:** completion ignores accents and the filter doesn't. `sao` completes to a folder or collection named São Paulo, but the same `sao`, as text or as `in:sao` or `city:sao`, doesn't find it.
- **Left** ([section 8](#8-left)): the agent that follows changes while Cling is closed, the wait after each keystroke, the cull of vague queries, folder importance in ranking, and everything outside search.
- **Accepted by the owner** on 7 October 2026 ([section 7](#7-proposed-tracker-changes)): one new row (the mapped column store), wording for LIB-06, LIB-18 and LIB-19, and text that ignores accents everywhere; the wording proposed for LIB-08 and LIB-04 isn't taken up for now. The library orchestrator adds them to the tracker.

## 1. How Cling works

### 1.1 The index

- **One index file per search scope and per drive,** mapped into memory rather than read ([CL2], [CL3]). The file is a 16 KB header and then one section per column, each starting on a 16 KB boundary (the page size on Apple silicon) and laid out exactly as the engine keeps it in memory, so loading it is a mapping with nothing to convert. About 160 bytes a file on disk ([CL1]).
- **What it keeps for each path:** its bytes with ASCII letters lowercased, all paths in one byte array, with a 4-byte offset and a 2-byte length; one bit per byte marking the uppercase letters, so a path is spelt again only for the few results shown; three 64-bit masks (which letters and digits the path holds, which its name holds, and where its name's words start); a 16-bit extension ID shared by every index; and 4 bytes for where the name starts, the depth and two flags. No path is kept as a `String`.
- **Mapped copy-on-write, with room to grow:** each column's pages from the file are mapped privately into a reserved region; pages that aren't written belong to the file cache, don't count toward the app's memory, and are dropped by the system under pressure and read back when touched. A change copies only the page it writes. A removed path is zeroed where it is and its slot isn't reused, so mapped pages stay clean; new paths go into anonymous memory after them. The index is saved again after 20,000 changes or six hours.
- **Memory as Activity Monitor counts it,** from `mincore`: the pages written (anonymous, modified or copied) and those compressed or paged out. The index size view shows each index's files, size on disk, memory and when it was last walked in full ([CL1]).
- **Per-search buffers from `mmap`,** returned with `munmap` when the search ends. By Cling's comments, freed `malloc` blocks of that size stay in the allocator's cache and keep counting toward the app's memory, which left hundreds of megabytes behind after a broad search ([CL3]).
- **A cold file read ahead with one request,** `fcntl(F_RDADVISE)` over the whole file. By Cling's comment, page faults bring a cold file in at about 1 GB/s, where one read-ahead request lets the SSD deliver at its own speed, 9 GB/s on an M5 ([CL3]).
- **Paths found by a table of 32-bit IDs,** open addressing over a hash of the stored bytes, 4 bytes a slot, holding no path itself.

### 1.2 A search

- **The query** is read as fuzzy words, extensions (`.pdf`), folder segments (`photos/`), `in:` folders, a depth, and fzf's operators (`'exact`, `^start`, `end$`, `!not`) ([CL2]).
- **Filter, across all cores:** the query's letter mask against each path's, then the extension as one 16-bit comparison, folder prefixes through a sorted index, excluded paths through a set of IDs. Most paths fail the mask test, one AND and a comparison. (A SIMD version of the mask test is in the file but nothing calls it; SIMD is used for finding bytes while scoring.)
- **Vague queries are bounded:** past 200,000 candidates, only the shortest paths are kept, except those whose name holds every letter of the query, up to 50,000 of them.
- **Score, across all cores:** fzf's scoring of the name and of the whole path (16 a letter, more at a word's start, after a delimiter, at a camelCase hump and in runs, −3 to open a gap and −1 to extend it), from each of up to 32 places the first letter appears; each word of a query of several scored on its own; cancellation checked every 512 candidates.
- **Typos:** a query of four letters or more, letters and digits only, is read again with one letter left out, or two from eight letters; an extra, a wrong or a swapped letter each comes down to one left out. A reading has to start where a word of the name starts and end where it ends, give or take a plural `s`; a word's first letter is never left out, and a query with fewer than a quarter vowels is taken for an abbreviation, not a typo. A bit-parallel longest common subsequence ([HY04]) rules out nearly every name before any reading is tried. Misspelt names rank after every name that holds the query as typed, and a second typo costs twice the first.
- **Ranking:** a key of, in order, whether the name matched, whether it starts with the query or a word of it does, how important its folder is (Documents, Desktop and Pictures first, hidden folders last), the name's score, how tight the match is, the path's score, depth and length. A quality floor drops results whose match is less than 40% as dense as the first-ranked one's in their index, and less than a third of the best across indexes, unless their name matched.
- **Every index at once:** all of them are searched in parallel; after 150 ms, what the finished ones found is shown; typing waits 150 ms before a search starts ([CL4]).
- **Text that isn't ASCII:** paths are kept as the disk gives them, with ASCII lowercased, and the query is tried decomposed (NFD, the form Cling's comments take APFS to store) and composed (NFC). Lowercasing ASCII also covers accented Latin capitals in a decomposed name, since NFD writes `É` as `E` and an accent; the masks hold only ASCII letters and digits, the same in both forms.

### 1.3 Following changes

- **A file-level FSEvents stream,** its deliveries handed over as one batch on a queue of its own, without `NoDefer`, so changes wait out the latency together instead of waking the app after every quiet spell, and flushed when someone is looking ([CL5]).
- **Launch replays each index from the event it was saved at;** a scope is walked again only when that history is gone.
- **The busiest folders the walks skip are left out of the stream** with `FSEventStreamSetExclusionPaths`, which takes at most eight. They're chosen by changes counted an hour, a count that halves each day so a folder that went quiet gives its place up; by Cling's comment, temporary files, build output and caches were nearly half the changes reaching it.
- **While Cling is closed,** a launchd agent registered with `SMAppService` wakes every 15 minutes; every three hours, once nobody has touched the Mac for 30 minutes (or after six hours regardless), it reads the FSEvents history since the saved indexes into a journal of paths and flags. The next launch applies it and replays only what came after ([CL6]).
- **A rename that changes only case** keeps the new spelling and drops the old one, which a case-insensitive disk still finds; a path that fails to `lstat` for any reason other than being gone (Full Disk Access withdrawn, say) is kept.

## 2. Against the library

| What Cling does | The library today (library/catalog) | Here |
| --- | --- | --- |
| Fuzzy scoring of every candidate, under 100 ms for 9 million paths | Bitsets over a column store; first page and count p95 2.5 ms at a million photos | Library ahead; nothing to take |
| A letter mask before scoring | Text through FTS5's trigram index, 0.22 ms for four characters at a million | Not needed there; used in [section 5](#5-short-text-fuzzy-matching-and-typos-lib-06-lib-18-lib-19) |
| Columns mapped from a page-aligned file | Columns built from SQLite into arrays at each launch | [Section 4](#4-the-column-store-mapped-from-a-file-lib-05-lib-06) |
| Read-ahead of a cold file | The index mapped with `MADV_WILLNEED` (`LibraryIndex.readAhead`) | Covered |
| Paths as bytes, matched as bytes in any script | Bytes for ASCII; Foundation's search per name otherwise (bytes for every script since e316f57) | [Section 3](#3-names-folded-to-bytes-once-lib-06); built |
| Searching from the first character | Free text under three characters dropped | [Section 5](#5-short-text-fuzzy-matching-and-typos-lib-06-lib-18-lib-19) |
| Fuzzy matching, typos, a quality floor | Completion by substring: the start, a word's start, inside | [Section 5](#5-short-text-fuzzy-matching-and-typos-lib-06-lib-18-lib-19) |
| What the finished indexes found, shown at 150 ms | The index shown at once; the first page as soon as it's full; facets cancelled by the next query | Covered |
| 150 ms before a search starts | A key's photos on screen within 16 ms | Left |
| Vague queries cut to the shortest paths | Counts that must be exact (the manifest's) | Left |
| Batched deliveries on a queue, no `NoDefer` | Folder-level events, 300 ms, on the stream's own queue, no `NoDefer` | Covered |
| Busy folders left out of the stream | Nothing left out | [Section 6](#6-busy-folders-under-a-root-lib-08) |
| Replay from the saved event | Per volume, 0.3 to 0.5 s at a million photos | Covered |
| An agent following changes while closed | None | Left |
| Memory counted with `mincore`; buffers from `mmap` | `phys_footprint` for the whole app (`Watchdog`) | [Section 4](#4-the-column-store-mapped-from-a-file-lib-05-lib-06) |
| Renames that change only case | Folders listed again rather than paths checked one by one; no test of a Finder rename in case alone | A test to add ([section 6](#6-busy-folders-under-a-root-lib-08)) |

## 3. Names folded to bytes once (LIB-06)

Built on library/catalog since this note was written (e316f57, `FoldedText`): names are case folded and decomposed once, matched by bytes and only where characters start and end, which keeps Foundation's case-only meaning; the library measures p95 0.38 to 0.78 ms a keystroke over 5,604 accented folder names. What follows is the prototype that measured the idea first; the question of accents below still stands.

The design's open point: "Free text that isn't ASCII matches folder paths with Foundation's search, about 45 ms a keystroke over 5,604 folders, where ASCII text takes under a millisecond." `NameMatcher` and `NameCodes` keep each name's bytes lowercased only when the name is all ASCII; once the text or the name isn't, `QueryText.contains` calls `range(of:options: .caseInsensitive)`, for every folder, camera, lens, creator and place.

The alternative: fold every name once when the vocabulary loads (case folded, then composed, NFC), fold the text the same way at each keystroke, and compare bytes with `memmem` whatever the script. A match that ends just before a combining mark is skipped, so `e` doesn't find the `e` of an accented `é`; UTF-8's continuation bytes never equal a character's first byte, so a match can't start in the middle of one.

`library_search` part 1, on 5,604 paths shaped as lib-1m's (`2007/2007-06-14 Wedding`, `Clients/Acme Corp/2019-03-02 Lookbook`), every query typed a character at a time; three runs at a load average of 62 to 70:

| A keystroke | Today | Folded bytes |
| --- | --- | --- |
| The fixture's folders (all ASCII), text that isn't ASCII (`São João`, `Zürich`, `東京駅`, `Ελλάδα` and four more) | p50 38.2 to 38.5 ms, p95 172 to 175 ms | p50 0.27 to 0.28 ms, p95 0.33 to 0.35 ms |
| The fixture's folders, ASCII text | p50 0.26 to 0.27 ms | p50 0.28 ms |
| A fifth of the folders named in other scripts, ASCII text | p50 6.4 ms, p95 7.0 to 7.1 ms | p50 0.27 to 0.28 ms, p95 0.35 to 0.43 ms |
| Folding the 5,604 paths once, at load | | 5.3 to 6.4 ms |

- **The same answers:** over all ASCII folders, 806,976 of 806,976 (text, folder) pairs agree with today's; with a fifth in other scripts (composed and decomposed, Greek, Japanese, Korean, Turkish `İ`, full-width letters), 806,872 of 806,976 do. The 104 that differ are all `stras`, in either case, against `Straße`: folding writes `ß` as `ss`, so the folded match is found while the word is still being typed, where Foundation waits for the whole `ss`. Both find `strasse`.
- **The SQL path** registers `QueryText.contains` with SQLite, so the two keep answering alike if the function folds both sides there too; it's the fallback until the column store loads, so its speed matters less.
- **The completion inconsistency:** completion's `QueryVocabulary.fold` ignores case, accents and width, and the filter ignores only case, so `sao` offers a folder named São Paulo that `sao` then doesn't find. Folding the filter's names the same way would make them agree; over the benchmark's pairs it adds 6,311 and 8,419 matches (`sao` for São João, `zurich` for Zürich, `fete` for Fête). That's a choice of what the language means, so it's a decision for the owner ([section 7](#7-proposed-tracker-changes)). FTS5's trigram tokenizer can ignore accents too (`remove_diacritics`, from SQLite 3.45; macOS 26 has 3.51), which needs the text index built again ([SQ1]).

## 4. The column store mapped from a file (LIB-05, LIB-06)

Today the column store is built from SQLite at each launch, in four parts across the index's readers (`IndexQuerySource.columnStore`): 459 to 634 ms at a million photos since the organising fields (the design's open points), 87.5 bytes a photo, all of it in `ContiguousArray`s that count toward the app's memory. The budgets it has to fit at a million photos: the library visible and searchable within 1 s of a warm launch, under 250 MB over launch and browsing, and under 120 MB idle after a memory-pressure trim.

`library_search` part 2 writes 27 columns of 87 bytes a photo for 1,000,000 photos (the store's columns, `rowOfID` and four sort orders) to an 83.4 MB file, each column on a 16 KB boundary, then loads it both ways; three runs, load average 61 to 63, the page cache warm:

| At a million photos | Held in arrays | Mapped copy-on-write |
| --- | --- | --- |
| Loading | 22 to 45 ms, read from the warm file (459 to 634 ms built from SQLite today) | 0.43 to 0.89 ms |
| The app's memory once loaded | +74.1 to 74.9 MB | +0.0 MB |
| A two-column pass (`rating>=3` and a camera), every row | p50 3.0 to 3.1 ms | p50 3.25 ms, and +0.0 MB after 20 of them |
| Every page of every column read | | 4.1 to 4.5 ms, +0.0 to 0.1 MB |
| A rating on 10,000 photos spread across the library | | +1.9 MB of pages copied |

- **What the mapping changes:** the columns stop counting toward the app's memory, about 74 MB at a million photos, and under memory pressure macOS drops their pages without the app doing anything and reads them back when a query touches them, which arrays can't do. A launch no longer builds the store before the library can be searched. A pass over mapped columns ran within 8% of the arrays.
- **Not measured:** a cold cache, after a restart or once the system has dropped the pages, which needs `sudo purge` from the owner's terminal, as LIB-03's cold runs do. Cold, the first queries read their columns from the SSD; one read-ahead request over the file, as Cling makes and as `LibraryIndex.readAhead` makes for the index, brings all 83 MB in at the disk's speed.
- **How it could work:**
  - A snapshot beside the index (`LibraryPaths`) holding the columns, the sort orders and the small tables' names, each section on a 16 KB boundary and laid out as in memory, written to a temporary name and renamed over the last after batches of commits and at quit, in the writer's lane.
  - Its header names the schema version and the index generation it reflects, a counter the writer bumps in every transaction. A snapshot whose generation matches the index's is mapped copy-on-write; any other is ignored and the store built from SQLite as today, so a snapshot never shows what the index doesn't hold. Launch's reconcile and every later change reach the store as they do now, through its updates.
  - Writes after launch land in copied pages; new photos are appended in memory of their own after the mapped rows; removed ones stay dead in `live`, as now, until the next snapshot compacts them.
- **Counting memory per component,** as Cling does with `mincore`, would let `--library-perf`'s memory phases say what the store, the lists and the thumbnails each hold, and Settings show the index's and the store's size on disk and in memory. Cling's finding about `malloc` keeping freed buffers is worth checking there: the library's per-query lists and sorts reach 8 MB at a million photos.

## 5. Short text, fuzzy matching and typos (LIB-06, LIB-18, LIB-19)

**Short text.** Free text under three characters is left out of the query entirely, small tables included, because the trigram index can't search it: `QueryParserTests` expects `ab rating:3` to search `rating:3` alone, and `東京` to search nothing. So `z8`, `R5` and `Q3` (camera names), or `東京` and `京都` (two-character place names), find every photo. The small tables don't need the trigram index: matched there, `r5` finds the Canon EOS R5, `z8` the NIKON Z 8 by its letters in order, and `東京` the folders holding 東京駅. The rule for names, titles and captions can stay as it is.

**Fuzzy matching and typos** suit completion (LIB-18) and the palette (LIB-19), which offer names ranked, and not the grid's filter, which has to say exactly which photos match and count them. `library_search` part 3 ranks names in tiers, on rules like Cling's: the name starts with the text, a word of it does, it holds it, it holds its letters in order (fzf's score), then one of its words is the text with one typo, or two from eight letters, for text of four letters or more, letters only. A typo is an extra, missing, wrong or swapped letter, counted by restricted Damerau-Levenshtein distance; Cling reaches the same edits by reading the query with a letter left out. Typos always come after every name that holds the text as typed, and letters-in-order matches scoring under half the best are dropped. Over 8,673 names (25 cameras, 20 lenses, 24 places, 3,000 keywords and lib-1m's 5,604 folders), every table at once, on one thread: p50 0.68 to 0.69 ms and p95 1.55 to 1.66 ms a keystroke, in two runs at a load average of 63 to 73.

| Typed | First found |
| --- | --- |
| `nz8` | NIKON Z 8 (camera), then NIKKOR Z lenses |
| `xt5` | X-T5 (camera) |
| `2470gm` | FE 24-70mm F2.8 GM II (lens) |
| `eosr6` | Canon EOS R6 Mark II (camera) |
| `lisbom`, `portgual` | Lisbon, Portugal (places), with one typo |
| `fujiflim` | FUJIFILM GFX100S (camera), one typo |
| `wedidng` | The Wedding folders, one typo |
| `nikkon` | The NIKON cameras, one typo |

- **One weakness seen:** for `landscpae`, letters in order scattered across `Subjects/landscape/black and white` outrank the word `landscape` one typo away. Cling's density floor and its scoring of a misspelt name as its correctly spelt twin are what avoid that; the benchmark has neither.
- **When a filter finds nothing,** LIB-18 already names the term whose removal brings back the most photos; a name one or two typos away from the text (Did you mean Lisbon?) belongs beside it.

## 6. Busy folders under a root (LIB-08)

`~/Pictures` is a natural folder to add, and Apple Photos keeps its library there by default, as Lightroom Classic keeps its catalogue and previews (`.lrdata`); their apps write in them while they run or sync. The walk never goes into a package (`FolderWalk.isFolder`), but change tracking doesn't leave their events out. Read from the code: `ChangeTracker.batch` turns every event under a root into a folder change, and `folder(of:below:)` drops only those in hidden folders; `LibraryIndexer.Run` walks a folder it doesn't index up to the nearest one it does (for a package in `~/Pictures`, the root itself) and lists that again; the run writes its roots' records, and `record(work)` writes the event position, after every batch, including batches with nothing left to update.

`library_search` part 4 watches a root with `VolumeEventStream`'s flags and `ChangeTracker`'s 300 ms latency while a `Photos Library.photoslibrary` inside it is written ten times a second for 20 seconds, then does the same with the package passed to `FSEventStreamSetExclusionPaths`; two runs:

| | Batches in 20 s | A second |
| --- | --- | --- |
| The root watched | 68, every one naming the package | 3.4 |
| The package left out | 0 | 0 |

At ten writes a second, that's the root listed again and the index written about three times a second, where DEC-40 asks for no work while idle. That's from the code and the OS's behaviour, not measured in the app; LIB-04 could measure it with a scenario of its own. Leaving packages out, as Cling leaves its busiest folders out, stops it at the source: the walk already meets each package, `FSEventStreamSetExclusionPaths` takes eight paths a stream (the busiest by events counted, past eight, as Cling chooses), and events inside a package can be dropped in `batch` before they become work. Writing the event position at most every few seconds, and at quit, costs a few seconds more of replay after a crash.

A rename made in Finder that changes only a name's case (`IMG_1234.CR3` to `img_1234.cr3`) is the other case Cling handles. The library lists a changed folder again rather than checking each path, so it should see the old name go and the new one come with the same file identifier; no test covers it.

## 7. Proposed tracker changes

The owner's answers (7 October 2026): the new row, the wording for LIB-06, LIB-18 and LIB-19, and the decision on accents (yes, everywhere) are accepted; the wording for LIB-08 and LIB-04 isn't taken up for now. None is in the tracker yet: the library orchestrator adds them. The new row is named "new", since its ID is given when it's added (the library's next is LIB-44 today).

**New row**

- **The column store mapped from a snapshot** (accepted; P4, M, Build; after LIB-06): the store's columns, sort orders and the small tables' names saved beside the index in one page-aligned file, each column on a 16 KB boundary as it's laid out in memory, written atomically after batches of commits and at quit, with the index generation it reflects; mapped copy-on-write at launch when its generation and schema match the index's, built from SQLite as today otherwise; later writes copy only the pages they touch; read ahead with one request on a cold launch ([section 4](#4-the-column-store-mapped-from-a-file-lib-05-lib-06)). Done when a warm launch at a million photos searches without building the store, and memory over launch and idle after a trim stays within 250 MB and 120 MB with the store's pages left to the file cache.

**Wording**

- **LIB-06** (accepted): free text under three characters still matched against folders, cameras, lenses, creators, places and keyword synonyms, only the trigram index's part left out ([section 5](#5-short-text-fuzzy-matching-and-typos-lib-06-lib-18-lib-19)). Matching text in every script as bytes, proposed here first, is built (e316f57).
- **LIB-18** (accepted): completion ranked by where the text matches (the start, a word's start, inside), then by its letters in order, then by a word one typo away (two from eight letters; letters only, four or more, never a word's first letter), always after every name that holds the text as typed, within a quality floor of the best match; a filter that finds nothing also offers a name one or two typos away.
- **LIB-19** (accepted): folders, collections, keywords, cameras, lenses and places by name, ranked as completion ranks them; photos by name through the text index.
- **LIB-08** (not taken up for now): packages other than `.redlamp` sidecars, and other folders the walk skips, left out of each volume's stream (eight a stream; past eight, the busiest by events counted); events inside a package dropped before they become work; the event position written at most every few seconds and at quit.
- **LIB-04** (not taken up for now): memory per component as Activity Monitor counts it (pages written or compressed, from `mincore`) in `--library-perf`'s memory phases; and a scenario with a package under a root written ten times a second for a minute, counting indexer runs and index writes, with a budget of none.

**Decision**

- **New, after DEC-44** (accepted: yes, everywhere): does text in the library ignore accents and width, as completion already does, so `sao` finds São Paulo and `zurich` finds Zürich? Yes, for the small tables, completion and the text index alike, so a name typed without its accents still finds the photos: `FoldedText` (e316f57) folds accents and width as well as case, and the trigram index is built again with `remove_diacritics 1`. On macOS 26.6's SQLite (3.51), a trigram index made that way finds São Paulo from `sao`, Zürich from `zurich` and Café from `cafe`, where the plain one finds none; it doesn't fold width, which would need the text folded before the writer puts it in the index (it holds no copy of its own, `content=''`).

**The README and the comparison,** once these are accepted: nothing changes a README checkbox. In `docs/lightroom-comparison.md`, "Search and filters" could add "names found with a typo or by their letters in order, in completion and the palette". Whether Lightroom Classic's Text filter forgives a typo isn't in the Lightroom feature inventory and wasn't checked here.

## 8. Left

- **The agent that follows changes while Cling is closed:** the library replays a volume's history in 0.3 to 0.5 s at a million photos, so a login item and a background job buy little, and they're one more thing for App Store review.
- **The wait after each keystroke:** 150 ms before a search starts is more than the filter bar's whole budget.
- **Cutting vague queries to the shortest paths:** the library's counts are exact, and its lists come from a pass over every row anyway.
- **Folder importance in ranking:** photos are ordered by the source's sort, not by where they sit, so the grid has nothing to rank; how the palette weighs its results is LIB-19's to decide.
- **Everything outside search:** the file server, sending files by link, the MCP server, the "Everything" index of every file, scripts and Quick Filters. The MCP server's "why doesn't my file show up" is LIB-18's empty-search help and Library Health's findings in another form.

## Measurements

`research/prototypes/library_search/run.sh` builds and runs all four parts (`run.sh 1 3` runs some), writing to `build/proto-out/library_search/results.txt`. They ran on an M1 Ultra (16 performance and 4 efficiency cores, 128 GB), as the library's own results did, on macOS 26.6.2, with other agents building (load average 60 to 73), so the timings are conservative. `TodayMatcher` is `QueryText.contains` and `NameMatcher` as they are on library/catalog; part 2 measures memory with `phys_footprint`, as `Watchdog` does.

## Sources

Cling's files are at commit e55f4f3b05d5f80b0b791fdfecb87da23c38e4d4, read on 6 October 2026.

- [CL1] Cling, README. <https://github.com/FuzzyIdeas/Cling/blob/e55f4f3b05d5f80b0b791fdfecb87da23c38e4d4/README.md>
- [CL2] Cling, `Cling/SearchEngine.swift`: the columns, the file format, the query, the filter, scoring, typos and ranking. <https://github.com/FuzzyIdeas/Cling/blob/e55f4f3b05d5f80b0b791fdfecb87da23c38e4d4/Cling/SearchEngine.swift>
- [CL3] Cling, `Cling/IndexStorage.swift`: mapped columns, read-ahead, per-search buffers and the path table. <https://github.com/FuzzyIdeas/Cling/blob/e55f4f3b05d5f80b0b791fdfecb87da23c38e4d4/Cling/IndexStorage.swift>
- [CL4] Cling, `Cling/FuzzyClient.swift`: every index searched at once, results at 150 ms and the merge. <https://github.com/FuzzyIdeas/Cling/blob/e55f4f3b05d5f80b0b791fdfecb87da23c38e4d4/Cling/FuzzyClient.swift>
- [CL5] Cling, `Cling/LiveIndex.swift`: the FSEvents stream and the folders left out of it. <https://github.com/FuzzyIdeas/Cling/blob/e55f4f3b05d5f80b0b791fdfecb87da23c38e4d4/Cling/LiveIndex.swift>
- [CL6] Cling, `Shared/ChangeJournal.swift`, `ClingCLI/CatchUp.swift` and `LaunchAgents/com.lowtechguys.Cling.catch-up.plist`: changes gathered while Cling is closed. <https://github.com/FuzzyIdeas/Cling/tree/e55f4f3b05d5f80b0b791fdfecb87da23c38e4d4/Shared>
- [CL7] Cling, release notes for 2.8.0, the index engine that took its memory from several GB to 60 to 100 MB. <https://github.com/FuzzyIdeas/Cling/blob/e55f4f3b05d5f80b0b791fdfecb87da23c38e4d4/ReleaseNotes/2.8.0.md>
- [FZF] fzf, `src/algo/algo.go`, which describes its first and second matching algorithms (MIT). <https://github.com/junegunn/fzf/blob/master/src/algo/algo.go>
- [HY04] H. Hyyrö, "Bit-Parallel LCS-length Computation Revisited", Proceedings of the 15th Australasian Workshop on Combinatorial Algorithms (AWOCA 2004).
- [SQ1] SQLite, FTS5, the trigram tokenizer's options. <https://www.sqlite.org/fts5.html#the_trigram_tokenizer>
