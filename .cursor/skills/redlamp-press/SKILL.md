---
name: redlamp-press
description: The press room, where every outlet Redlamp is pitched to (newsletters, Mac and photography sites, developer and open-source communities, lists and directories) is tracked from finding it to its coverage, in a canvas the owner sends from. It holds each outlet's way in, a pitch written for it, the waves they go out in, Gmail drafts the owner sends himself, replies, follow-ups and the pull requests to lists. Use when finding outlets or their contacts, writing or checking a pitch, preparing the next wave, recording a reply or coverage, following up, or asking who has been pitched and what came of it.
---

# The press room

Every pitch is tracked in one canvas, the press room: the outlets worth writing to, how to reach each one, the pitch written for it, the wave it goes out in, and what came back. The owner sends every email and fills in every form himself; agents find outlets, write and check pitches, prepare drafts and keep the room up to date.

## Where

| What | Where |
| --- | --- |
| The room | `~/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/ws-press-outreach.canvas.tsx`, from [template.tsx](template.tsx). It began as a workstream canvas and keeps that name, which the outreach script expects. Edit its `workstream` object and its DATA block (the outlets, the pitch templates, the blurb); the script writes GMAIL, LOGGED and PRS. A change to the rendering goes into the template and the room together. |
| The owner's marks | `ws-press-outreach.canvas.data.json` beside it: each outlet's status and when it changed, when it was sent, its reply, the tab and filters, and Needs you marks. Only the canvas writes it. |
| The outreach script | `~/src/redlamp-outreach/outreach.py`, outside the repository because it holds the Gmail token. `auth`, `status`, `show <id>`, `drafts` (creates Gmail drafts for email rows still To do, and never sends), `sync` (records Drafted, Sent and Replied from the threads) and `prs` (checks each list's pull request: merged counts as Covered, closed as Declined). Its docstring has every option. |
| What never goes into the repository | Contacts, pitches, replies and the owner's address. They live in the room and its data file, on the owner's Mac; the template holds one example outlet at example.com. |

Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first edit of the room. Link the room in every reply that changes it: `[Press room](/Users/pedrogomes/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/ws-press-outreach.canvas.tsx)`.

## Every time: know where things stand

1. **Read the owner's marks first:** statuses, sent dates, replies and Needs you. Fold the Needs you marks into `workstream` as `.cursor/skills/workstream-canvas/SKILL.md` describes. Never write the data file.
2. **Run `outreach sync` and `outreach prs`** where the script is set up. Never take a status from memory.
3. **Bring the room up to date in the same turn:** `status`, `needsYou`, `plan`, a `log` entry and `updated`. Say plainly what you didn't check.

## Outlets

- Each outlet is a row in DATA's `outlets`: its group, kind and site; its way in (`route`: email, form, post, pull request or listing); its wave and priority; why it's on the list; and where its contact came from (`source`).
- Write to the address each outlet publishes for tips or reviews, never a list and never several outlets in one email.
- **Waves:** Now is what can go out this week. With the write-ups holds outlets that need something to read first; their Compose links unlock once the write-ups' addresses are filled in. Later holds rows that wait for something specific, which the row names. An outlet left out goes in `leftOut`, with the reason.

## Pitches

- A pitch is one of DATA's `templates`, by language and use, filled with the outlet's greeting and hook. The hook is its first line and is about the outlet: why its readers would care. Check that it's still true before the owner sends it.
- The room's writing rules apply to every pitch: one person per email, a line saying how Redlamp is built with a link to the site's AI disclosure, plain words (no superlatives, exclamation marks or em dashes), and links rather than attachments.
- Write in the owner's voice, as `.cursor/skills/redlamp-blog/SKILL.md` describes (Writing in the owner's voice), and claim only what the README says.

## Sending, replies and coverage

- **The owner sends.** Compose in Gmail opens a filled-in message in his account, and `outreach drafts` makes drafts without sending. An agent never sends an email, submits a form or posts on the owner's behalf.
- Once sent, a row is Sent; `outreach sync` records a reply, and Log reply records the outcome and what they said.
- **Follow up once,** a week after sending, in the same thread. After that, the row is No reply.
- Covered takes the link to the piece. A list's pull request is Covered once it's merged.

## Evolving the room

The owner shapes the room as needs come up. A new status, route or tab goes into the template and this skill in the same change, and the room picks it up. Commit both on main: `Press room: …`.
