---
name: workstream-canvas
description: Keeps a live Cursor canvas for a workstream (one agent's line of work) showing its goal, plan and progress, what's next (for the owner, ready, blocked), decisions and why, measurements and commits. Use when starting a new workstream or agent task, after a step lands (a commit, a tracker row's status, a measurement), when the owner decides something or a choice is made between approaches, when work becomes blocked or unblocked, and before wrapping up a session.
---

# Workstream canvas

Every workstream keeps one canvas the owner can open beside the chat to see where it stands without reading the transcript. It is brought up to date as the work advances, not at the end.

## Where

- `~/.cursor/projects/<workspace>/canvases/ws-<slug>.canvas.tsx`: `<workspace>` is the Cursor project folder for this repository (find it from absolute paths in the environment, or list `~/.cursor/projects/`); `<slug>` is a short kebab-case name for the workstream (`ws-copy-paste-sync`).
- One canvas per workstream. Edit only your own; another agent's workstream has its own canvas. If you continue someone else's workstream, keep its canvas.
- Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first write: its rules apply (theme tokens only, no empty states, label every chart).

## Start a workstream

1. Copy [template.tsx](template.tsx) to the path above.
2. Replace every value in the `workstream` object, and delete the example rows that don't belong. Leave the rendering code alone; an empty list hides its section.
3. Link the canvas in your reply: `[Workstream title](/absolute/path/ws-slug.canvas.tsx)`.

## Keep it current

Update in the same turn as the event, by editing only the `workstream` object:

| Event | Update |
| --- | --- |
| A step lands (commit) | Its `plan` status and `ref`; a `timeline` row (newest first); `stats`, `status`, `updated`, `lastCommit` |
| The owner decides, or you choose between approaches | Append to `decisions`: date, decision, why, and `by` (Owner, Measured, Default) |
| A measurement | `measurements` (or a stat), with what it's measured against in the caption |
| Work needs the owner, is ready, or becomes blocked or unblocked | `next.needsOwner`, `next.ready`, `next.blocked` |
| Before your final summary | `status`, `updated`, and the `next` lanes |

After each edit the tool result shows a `Canvas TypeScript check` line: fix errors until it reports none.

## What goes in

- **Only what you verified:** commits from `git log`, test counts you ran, tracker IDs and issue numbers as they are. Say plainly what isn't checked yet ("not tried in the app").
- **Next lanes:** "Needs you" is what only the owner can do (decisions, photos, measuring another app, trying the work in the app); "Ready" is unblocked work you could start; "Blocked" names its blocker (a `DEC-` row, an SDK, data). At most five each; take finished items out.
- **Decisions are history:** append, never rewrite. A reversed decision is a new row that says what it reverses.
- **The tracker stays the source of truth** (`.cursor/rules/tracker-issues.mdc`): plan steps reference tracker IDs and issues; the canvas summarises them, it doesn't replace them.
- Plain, complete sentences in the project's voice: calm, precise, no superlatives.
