---
name: workstream-canvas
description: Keeps a live Cursor canvas for a workstream (one agent's line of work) showing its goal, progress through the plan, what needs the owner (what each item unblocks, whether it blocks work, the command to run), what's ready or blocked, decisions and why, a timestamped log, and measurements. Use when starting a new workstream or agent task, after a step lands (a commit, a tracker row's status, a measurement), when something needs the owner or the owner does it, when the owner decides something or a choice is made between approaches, when work becomes blocked or unblocked, and before wrapping up a session.
---

# Workstream canvas

Every workstream keeps one canvas the owner can open beside the chat to see where it stands, and what it needs from them, without reading the transcript. It is brought up to date as the work advances, not at the end.

## Where

- `~/.cursor/projects/<workspace>/canvases/ws-<slug>.canvas.tsx`: `<workspace>` is the Cursor project folder for this repository (find it from absolute paths in the environment, or list `~/.cursor/projects/`); `<slug>` is a short kebab-case name for the workstream (`ws-copy-paste-sync`).
- One canvas per workstream. Edit only your own; another agent's workstream has its own canvas. If you continue someone else's workstream, keep its canvas.
- Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first write: its rules apply (theme tokens only, no empty states, label every chart).

## Start a workstream

1. Copy [template.tsx](template.tsx) to the path above.
2. Replace every value in the `workstream` object, and delete the example rows that don't belong. Leave the rendering code alone; an empty list hides its section or tab.
3. Link the canvas in your reply: `[Workstream title](/absolute/path/ws-slug.canvas.tsx)`.

## Boards: features with milestones

When the work is a feature with milestones, each made of tracker rows (the library, LIB-01 to LIB-35, is one), start from [board-template.tsx](board-template.tsx) instead. It shows overall progress and a bar for each milestone, a Now panel (what's being built, what waits on the owner, what's next), Needs you, every row with its state and issue, the measurements against their budgets, the agents with a button to open each conversation, and the plan's steps, log and decisions folded underneath.

- Fill in `BOARD`, `MILESTONES` (each row with its tracker ID, issue and state), `LATER`, `NOW`, `AGENTS`, `DOCS` and `workstream`; leave the rendering alone.
- A row's state is `done` (merged where it ships, its done-when met), `built` (merged and tested, with a check at scale or a small part left, which its note names), `doing`, `you` (waiting on the owner) or `todo`. Never call a row done that the tracker doesn't.
- Everything below applies to boards too: the owner's marks first, one step per todo, updates in the same turn, and only what was verified.
- For a post or a report, [capture.py](capture.py) renders a canvas outside Cursor with Cursor's own canvas runtime and captures its sections (its docstring has the commands); the blog post How I manage a large feature across AI agents was illustrated with it.

## A plan's todos are its steps

When the work has a plan (plan mode's `~/.cursor/plans/<name>.plan.md`, or one in `docs/plans/`), the canvas shows every todo:

- **The canvas is the plan's first todo.** Plan mode can't write it, so it's written as soon as the plan is approved, before any other todo starts.
- **One step per todo,** in the plan's order, with the todo's ID as the step's `id`, a short `step` and `detail` from its content, and `doneWhen` from the plan. Link the plan under `links`.
- **A todo and its step change in the same turn:** pending is `not started`, in_progress is `in progress`, completed is `done` and cancelled is `dropped`. `blocked` is the canvas's own, with the step's `note` saying what it waits on. A todo added or split gets its step at once, so the two lists stay one to one.

## What it shows

- **Overview:** progress through the plan; **Needs you**, open items first (blocking ones on top, with a command to copy) and done items folded underneath with what came of them; the Ready and Blocked lanes; the latest log entries.
- **The owner answers Needs you on the canvas:** each open item has **Done**, **Skip** and **Ask the agent**. Done and Skip fold the item away at once (with Undo). Ask the agent opens a new chat with the canvas attached and a prompt naming the item, and marks it "With an agent".
- **Plan:** each step with what it involves, its "done when" criterion, its reference (tracker ID, issue or commit) and its status.
- **Decisions**, the full **Log**, and **Measurements** when there are any.

## Keep it current

**First, read the owner's marks.** The canvas keeps them in `ws-<slug>.canvas.data.json`, beside it, under `needsYou`: `{ "<item id>": { "state": "done" | "skipped" | "asked", "at": "<ISO time>" } }`. Never write that file; fold each mark into `workstream` instead:

- `done`: set the item's `done: true` and its `detail` to "Done: …" with what came of it; check it where you can (a merge is in `git log`, a setting in the defaults), and say what you couldn't check.
- `skipped`: set `done: true` and `detail` to "Skipped: …", with what that leaves undone (a step now blocked or dropped, a `log` entry).
- `asked`: another agent was given the item in a new chat; leave it open until that agent, or the owner, marks it.

Then update in the same turn as the event, by editing only the `workstream` object:

| Event | Update |
| --- | --- |
| A step starts or lands (commit) | Its `plan` status and `ref`; a `log` entry; `status`, `updated`, `lastCommit` |
| A todo changes status, or is added, split or cancelled | Its `plan` step, mapped as in [A plan's todos are its steps](#a-plans-todos-are-its-steps) |
| Something only the owner can do | A `needsYou` item: exactly what to do and where (settings, paths, the shell line in `command`), what it `unblocks`, and `blocking: true` when work waits on it |
| The owner did it | `done: true`, and `detail` starting "Done:" with what came of it. Keep the item |
| The owner decides, or you choose between approaches | Append to `decisions`: date, decision, why, and `by` (Owner, Measured, Default) |
| A finding or a measurement | A `log` entry; `measurements` (or a stat), with what it's measured against in the caption |
| Work is ready, or becomes blocked or unblocked | `ready`; `blocked`, with `blockedBy` naming the blocker (a `DEC-` row, an SDK, data, an owner item) |
| Before your final summary | `status`, `updated`, the lanes, and a `log` entry saying where things stand |

`updated` and each log entry's `at` are ISO times with the time zone (`2026-10-04T07:40:00+01:00`), so the canvas can say how long ago. After each edit the tool result shows a `Canvas TypeScript check` line: fix errors until it reports none.

## What goes in

- **Only what you verified:** commits from `git log`, test counts you ran, tracker IDs and issue numbers as they are. Say plainly what isn't checked yet ("not tried in the app").
- **Needs you:** what only the owner can do: decisions, accounts and secrets, photos, measuring another app, trying the work in the app, merging. Each item says how to do it without opening the transcript, and what it unblocks. Keep done items; they are the record of what the owner did.
- **Log:** one short paragraph per entry, newest first: what happened, what was found, what's queued next. It is the narrative the owner reads to catch up, so name commits, counts and blockers.
- **Lanes:** "Ready" is unblocked work you could start; "Blocked" names its blocker. At most five each; take finished items out.
- **Decisions are history:** append, never rewrite. A reversed decision is a new row that says what it reverses.
- **The tracker stays the source of truth** (`.cursor/rules/tracker-issues.mdc`): plan steps reference tracker IDs and issues; the canvas summarises them, it doesn't replace them.
- Plain, complete sentences in the project's voice: calm, precise, no superlatives.

## Canvases from the earlier template

Canvases made before this template (one page with lanes and a commit timeline) keep their format: keep updating their own fields. Move one to this template only when its owner asks.
