---
title: How I manage a large feature across AI agents
summary: Redlamp's library is the largest thing it has taken on, built by a string of AI agents, each in a chat of its own. This is how I keep track of it without reading their transcripts, and the skill you can borrow to do the same.
date: 2026-10-05
cover: board-overview.png
coverAlt: The library's board in Cursor, with overall progress across the library's core and a progress bar for each milestone
---

I'm building Redlamp, a raw photo editor for macOS, with AI agents in Cursor. I decide what I want to build, work through the design, and try and review what comes back. The agents write most of the code.

So far, the app has focused on editing: open a folder, develop your photos, and save the edits in sidecar files alongside the originals. Today I started work on the library module: ratings, flags, keywords, collections and search.

I want this to work with the kind of libraries photographers accumulate over years. That means hundreds of thousands of photos, potentially millions, spread across SSDs, spinning disks and network storage. Search needs to feel immediate, and moving through a shoot should stay responsive even when you hold down an arrow key.

There's quite a lot involved, and it quickly becomes more work than I can reasonably manage in one chat. By the end of the first day, eleven agents had worked on the feature and a twelfth was running. Each had its own context, and none of their conversations gave me a complete view of where things stood.

I needed a way to follow the work, review decisions and see where I had to get involved without spending the day reading agent transcripts. This is the setup I'm using.

## Planning the work

I started in Cursor's plan mode. Before proposing an implementation, the agent used three other agents to inspect the existing folder browser, sidecar handling, command palette and keyboard shortcuts.

There was already useful work to build on. The folder browser could list 50,000 photos in around 200 ms. But there was no database, ratings only applied to the open photo and had no undo support, and thumbnails were cached by file path, so renaming a file invalidated its thumbnail.

The agent then asked me two questions that would materially affect the design: where the library metadata should live, and whether this belonged in the 1.0 release.

I chose to keep ratings, keywords and collection membership in the sidecars. The database would be a rebuildable index. Redlamp would read existing XMP metadata, with writing back to XMP available as an explicit option. I also decided to include the core library in 1.0.

As the plan developed, I added a few requirements. Performance needed to be part of the initial design, backed by benchmarks. Mouse workflows needed the same attention as keyboard workflows. And the library and editor should be modules within the same window, with immediate switching between them, much like Lightroom Classic.

We also looked at how other photo apps handle sidecar storage. The default would be alongside each photo, with an option to use Redlamp's own folder on the Mac when the source folder isn't writable.

These decisions all went into the project record with their rationale. The unresolved ones went in too: whether to index GPS data and whether to import ratings and keywords directly from Lightroom Classic catalogs. I want a new agent to be able to distinguish an agreed decision from something we're still considering.

## Keeping the plan outside the chats

Redlamp has a [research tracker](https://github.com/pdcgomes/redlamp/blob/main/docs/research/research-tracker.md) that holds the planned work. Each item has an ID, a status and references to the commits that implement it. Open items also have GitHub issues, so the roadmap can be followed publicly.

Two scripts keep the other views in sync. One creates and updates GitHub issues from the tracker. The other updates the README roadmap and the [Lightroom comparison](https://redlamp.app/compare) on the website.

The library plan became 35 items, `LIB-01` through `LIB-35`. Thirty belong to the 1.0 core; the remaining five cover AI features and a map, which will come later.

Other agents are working on Redlamp at the same time, so this shared record matters. While the library plan was being written, an agent researching tethered shooting added six decisions using the numbers the library agent had expected to use. The library decisions had to be renumbered.

That's a small coordination issue, but it illustrates why I don't want the project state to depend on what an individual agent remembers from its chat.

## A board I can actually use

Cursor's canvas gives me a place to see the state of the work alongside the conversation. It's a React page maintained by the agent, and I've been using one for each workstream.

For smaller tasks, a step list and an activity log are usually enough. For the library, I wanted an overall view and progress by milestone, similar to a production board I use on another project.

The board shows the 30 core items grouped into groundwork, foundation, grid and culling, organisation, file operations, and migration from other apps. At the top, I can see what's being worked on, what's next and anything waiting on me. Each item links to its GitHub issue and describes what has been implemented and what remains.

Further down are the performance measurements, a record of the agents involved with links to their chats, and the plan, activity log and decision history. The detail is there when I need it, but I can get a useful overview without reading all of it.

![The board's Now panel beside its Needs you list](board-now.png "Now says what's being built and what's next; Needs you says what only I can do.")

### What counts as complete

One thing I wanted to be explicit about was the difference between having an implementation and having finished the work.

The board has five states: not started, in progress, waiting on me, built and done. An item is *built* when its code has been merged into the library branch and tested, but still has outstanding checks or scope. It's *done* when it meets all the requirements in the plan.

The tracker has an additional constraint: items remain in progress until the code reaches main, because marking them done closes their GitHub issues.

At the time of writing, six of the thirty core items were built and none was done. The board therefore showed 0% complete, while displaying the built work separately. I'm comfortable with that. I need to know how much remains before I can ship it.

The same approach applies to the measurements. Commit references come from git, test counts come from test runs, and benchmark results include the workload and the conditions under which they were measured.

For example, the indexer needs to make the first 1,000 photos searchable within two seconds. It achieved that in one of four runs on a busy Mac. That's what the board reports, with the target shown on the chart. There's still work to do before I can call that requirement met.

![The foundation milestone's rows, each with its state, its GitHub issue and a line on what's in and what's left](board-milestone.png "Each row links to its issue and says what's left before it's done.")

### Making my part clear

The board also has a “Needs you” section. Each entry explains what I need to do, what it enables and whether anything is blocked. It should contain enough information for me to act without opening the original conversation.

On the first day, that included running a benchmark with the file cache cleared, making the GPS and Lightroom catalog decisions, deciding when to merge the library work into main, and connecting a real NAS share to check the simulated network results.

The benchmark requires mounting a disk image, which Cursor's sandbox doesn't allow, so the entry includes the command for me to run in Terminal. None of these items was blocking the current work.

I can mark an entry Done or Skip, or open a new chat with the board attached to discuss it. The agent picks up those responses when it next updates the canvas.

![Marking a Needs you item done, opening the Done group, then undoing it](board-needs-you.gif "Done folds an item away and Undo brings it back. The agent picks the answer up at its next update.")

## Performance from the start

I was fairly insistent that performance testing come before feature implementation. The library needs to remain usable at scale, and I wanted the design decisions informed by measurements early on.

The test infrastructure generates synthetic libraries of up to two million photos, with known result counts for each search. It also simulates storage delays for spinning disks, network shares, Wi-Fi and VPN connections. Benchmarks report a pass or fail against the agreed targets.

The initial targets include search within 16 ms at a million photos, UI actions reflected within a frame, and no blank frames while navigating with an arrow key held down.

These tests have already affected the implementation in two useful ways.

First, SQLite took around 60 ms to count matches for two filters across a million photos. That exceeded the search budget, so the design was extended to keep the data needed for search in memory. The search engine built on that returned results in 2.1 ms in the measured test.

Second, the indexing benchmark exposed a concurrency bug. Indexing a 20,000-photo test library took 185 seconds. Although multiple readers were meant to run per disk, parsing was making them wait, effectively serialising the reads. After the fix, the same benchmark took 26 seconds.

Those are useful results, but they don't establish that the entire library meets its targets. The board keeps the individual measurements visible alongside the checks that remain.

![The board's Measured so far: indexing speed against its target, metadata reads by raw format, and the search engine's figures at a million photos](board-measured.png "Every figure says what it was measured against, and how busy the Mac was.")

## Coordinating the agents

The library is being developed in its own git worktree and branch while other work continues on Redlamp. I merge main into it regularly; main had advanced by 65 commits between starting the feature and the first merge.

Agents implementing individual parts also get their own worktrees and a defined set of files they can change. The design document establishes ownership and interfaces before implementation starts, so the database, benchmark infrastructure and other components have an agreed way to fit together.

There have been a couple of problems with the process already.

Twice, attempts to start several agents together hit resource limits. One stopped partway through, and another picked up from its committed work. For now, the library agents run sequentially, and the board records which agent is active and how the previous ones finished.

I also caught a problem with issue synchronisation. The library branch had an older copy of the tracker, and running the sync script from it would have reopened two issues another agent had just closed. Syncing from that branch is now restricted to the library's own items.

Both are things I need to see when following the work. A progress view is more useful when it includes interrupted work and coordination problems.

## Trying it in another project

The instructions behind the board are packaged as a Cursor skill called [workstream-canvas](https://github.com/pdcgomes/redlamp/tree/main/.cursor/skills/workstream-canvas). You can copy the folder into your project's `.cursor/skills/` directory.

It includes the instructions in `SKILL.md`, a template for individual workstreams, a board template for larger features, and a capture script that renders canvases outside Cursor. That's how I generated the screenshots in this post.

It uses some Redlamp conventions, particularly the research tracker, [`tracker-issues.py`](https://github.com/pdcgomes/redlamp/blob/main/scripts/tracker-issues.py), [`roadmap-sync.py`](https://github.com/pdcgomes/redlamp/blob/main/scripts/roadmap-sync.py), and the coordination rules in [`AGENTS.md`](https://github.com/pdcgomes/redlamp/blob/main/AGENTS.md). You'd need to adapt those to your project. Cursor's own canvas skill handles the rendering; this skill defines what to show and when to update it.

The library is still in progress. The foundation needs its thumbnail and preview store, the result lists that will feed the grid, and support for keeping sidecars on the Mac. After that comes validation against a million-photo library.

What I find useful so far is being able to leave a conversation and come back without reconstructing everything that happened. I can see the current state, understand why a decision was made and pick up the things that need my attention. A new agent can use the same record to continue the work.

Once the library is complete, I'll write more about the implementation, the benchmarks and the design changes that came out of them.
