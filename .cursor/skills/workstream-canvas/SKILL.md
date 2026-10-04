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

## What it shows

- **Overview:** progress through the plan; **Needs you**, open items first (blocking ones on top, with a command to copy) and done items folded underneath with what came of them; the Ready and Blocked lanes; the latest log entries.
- **Plan:** each step with what it involves, its "done when" criterion, its reference (tracker ID, issue or commit) and its status.
- **Decisions**, the full **Log**, and **Measurements** when there are any.

## Keep it current

Update in the same turn as the event, by editing only the `workstream` object:

| Event | Update |
| --- | --- |
| A step starts or lands (commit) | Its `plan` status and `ref`; a `log` entry; `status`, `updated`, `lastCommit` |
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
