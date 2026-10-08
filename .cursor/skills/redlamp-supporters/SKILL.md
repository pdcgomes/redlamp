---
name: redlamp-supporters
description: The supporters room, where Redlamp's funding is run in a canvas the owner approves and posts from. It holds the Patreon page and redlamp.app/support, the tiers, what Redlamp costs and the funding ladder those figures make, the members' monthly letter, the quarterly ranking of what's built next, the supporters list, and the quarterly report of what came in and where it went. Use when working on Patreon, Ko-fi, GitHub Sponsors, memberships, donations or supporters; drafting the page, a letter, a ranking or a report; updating the figures or the credits; or asking what support brings in and what it pays for.
---

# The supporters room

Redlamp is free and open source, and support pays for the work: its running costs, its research and the owner's time. The supporters room is the canvas where that is run: the pages people join from, the tiers, the figures and the ladder they make, what's posted to members, and what came in and where it went. The owner approves the copy, enters the figures and posts everything himself; agents draft, gather the material and keep the room.

## The promise

Every page, post and change keeps to it:

- Nothing is held back for supporters: no feature, build or fix. Bugs are fixed by severity, never by tier.
- Members set the order of work the owner has already accepted. They don't decide what goes on the roadmap, and Report a Bug and Send Feedback stay the same for everyone.
- Money is reported in totals, and members are credited only as they ask to be.

## Where

| What | Where |
| --- | --- |
| The room | `~/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/supporters-room.canvas.tsx`, from [template.tsx](template.tsx). Edit only its `room` object. A change to the rendering goes into the template and the room together. |
| The owner's marks and figures | `supporters-room.canvas.data.json` beside it: `needsYou` (Done, Skip, Ask the agent), `posts` (Posted, Scheduled, Skip) and `figures` (running costs, research budget, full-time income and Ko-fi so far, as he typed them). Only the canvas writes it. |
| The platforms | Patreon for memberships, and Ko-fi (`ko-fi.com/pdcgomes`) for one-off tips. Once redlamp.app/support exists, every support link points at it, never straight at a platform: the app's `SettingsView.supportURL`, the README's badge and closing line, and `web/lib/site.ts`. |
| What never goes into the repository | Members' names (other than as they asked to be credited), emails, messages and what each pays, and the owner's figures until he publishes them. They stay in the room and its data file. The template holds the page drafts and nobody's details. |

Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first edit of the room. Link the room in every reply that changes it: `[Supporters room](/Users/pedrogomes/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/supporters-room.canvas.tsx)`.

## Every time: know where things stand

1. **Read the owner's marks first.** Fold the `needsYou` marks into `room` as `.cursor/skills/workstream-canvas/SKILL.md` describes, each post's mark into its `state`, and the figures into `room.figures`, with the date in `recorded`. Never write the data file.
2. **Check what you report.** Members and money come from the platforms' exports or the owner's word, rows from the tracker, and commits from `git log`, never from memory.
3. **Bring the room up to date in the same turn:** `summary`, `stage`, `needsYou`, `plan`, a `log` entry and `updated`. Say plainly what you didn't check.

## The pages

- **Patreon:** the headline, About (with the ladder, built from the figures), each tier's description, the welcome note and the questions. **redlamp.app/support:** membership, Ko-fi, sample files on raw.pixls.us, Test Your Camera, and Report a Bug or Send Feedback. Both are drafted in `room`, and go nowhere until the owner approves them.
- **The ladder** is cumulative: running costs, then the research budget, then a fifth, a half and all of the full-time income. The canvas turns each step into pledges a month at an average of $8 a member, after Patreon's fees at the rates its Money tab names (`fee()` in the template). Check those rates on Patreon's pricing page before the owner sets prices.
- A change to a tier's price or perks changes the tiers, About, the questions and the support page together.
- Write in the owner's voice, as `.cursor/skills/redlamp-blog/SKILL.md` describes (Writing in the owner's voice), and claim only what the README says.

## The monthly letter

Early each month, to every member, in about 400 words. Draft it from what the repository records for the month; the owner edits and posts it.

- **What shipped:** the month's releases (`gh release list`) and their What's New, and the tracker rows that became Done (`git log` on `docs/research/research-tracker.md`).
- **What's next and why:** the rows in progress, and the next ranked row.
- **What it cost:** the month's costs and what came in, in totals.
- **Something learned:** a research note or a measurement from the month (`docs/research/notes/`, the blog).

Add it to `posts` as a `letter`, with its audience and due date, and a Needs you item to post it.

## The quarterly ranking

1. Pick three to five rows that are `Accepted` and `Not started`, in the current phase and sized S or M, that the owner is happy to build next. He approves the shortlist (a Needs you item).
2. Draft the poll for Insider and Studio members: each row in plain words, with its issue. Add it to `posts` as a `ranking`.
3. Once the poll closes and the owner gives the result, the top row goes next. Add "supporters' pick" and the quarter to its Decision cell in the tracker (`Accepted (2026-10-01): …; supporters' pick, 2027 Q1`), sync the issues (`.cursor/rules/tracker-issues.mdc`), and draft the result for every member.

## The quarterly report

At the end of each quarter, a post for everyone: members at the end of the quarter, what came in from Patreon and Ko-fi after fees, each cost, and what's left over and where it goes. Totals only. Add the quarter to `money`, and the post to `posts` as a `report`.

## The supporters list

The welcome note asks each member how they'd like to be credited: by name, by a handle, or not at all. Only those who answer with a name or a handle are listed, in the app and on redlamp.app, with founding supporters (those who joined in the first month) marked. The list holds names only. It's built when the first member asks to be credited (the plan's `credits` step), and this skill then says where it lives.

## Evolving the room

The owner shapes the room as needs come up. A new list, state or button goes into the template and this skill in the same change, and the room picks it up. Commit both on main: `Supporters room: …`.
