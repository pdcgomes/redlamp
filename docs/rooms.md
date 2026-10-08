# The rooms

Redlamp is run from four rooms: canvases beside the chat in Cursor, each kept up to date by agents through a skill, where the owner sees where things stand and makes the decisions that are his. Releases, the reports people file, the blog and press outreach each have one. This document says what each room is for, what it shows and how it works; each room's skill has what an agent needs to keep it.

## How a room works

- **A canvas, kept by a skill.** A room is a canvas, a single React file that Cursor renders beside the chat, kept in `~/.cursor/projects/<workspace>/canvases/` on the owner's Mac. Its skill in `.cursor/skills/` says where the room's information comes from and how an agent keeps it current, and its `template.tsx` holds the rendering with an empty example of the data. An agent working from a skill reads the room first and brings it up to date in the same turn as the work.
- **The owner decides on the board.** Each room lists what needs the owner, with buttons for the decisions that are his: approve a release, triage a report, mark a post as shared, send a pitch. His clicks are kept in a data file beside the canvas, which only the canvas writes. Agents read it and act on it, and every item says what it unblocks.
- **Buttons open chats.** A button such as Fix it or Ask the agent opens a new agent chat with the room attached and a prompt for that one job, so each piece of work gets a short conversation of its own.
- **Scripts do the reading.** Where a room follows something outside the code, such as GitHub issues, the blog's posts or Gmail, a script reads it on the Mac and writes the room's generated part, so keeping a room current takes few tokens.
- **Shared code, private state.** The skills and templates are in the repository. The rooms themselves, with the owner's marks and notes, stay on the owner's Mac. A new list, state or button goes into a room's template and its skill in the same change.

## The release room

Where each release is prepared, checked, approved and shipped. [Skill](../.cursor/skills/redlamp-release/SKILL.md) and [template](../.cursor/skills/redlamp-release/template.tsx).

- **What it shows:** the latest and the upcoming release; what's in scope and what's held back; What's New; each check with its result, counts and commit; each problem with the owner's decision; the release plan; and the history, log and decisions. Its tabs are Overview, Scope, What's New, Checks, Problems, Release plan, History, Log and Decisions.
- **What the owner does:** settles the scope and each problem, approves What's New and the release notes, tries the candidate, and approves the release. He runs the release command in his own Terminal, because notarizing needs his keychain.
- **What agents do:** run `scripts/release-status.py`, the test suites, the regression suite and a dry run in a worktree kept for releases; write What's New and the release notes; and once the release is out, record it and bring the reports room up to date.
- **Its rule:** nothing in the release plan runs until the owner approves the release, and an approval lapses if anything changes after it.

## The reports room

Where every report people file, from the app's Report a Bug and Send Feedback or on GitHub, is followed from its arrival to the release that ships its fix. [Skill](../.cursor/skills/redlamp-reports/SKILL.md), [template](../.cursor/skills/redlamp-reports/template.tsx), [room.py](../.cursor/skills/redlamp-reports/room.py) and the [bug agent's brief](../.cursor/skills/redlamp-reports/bug-agent.md).

- **What it shows:** each report in the reporter's own words, with its area, version and Mac; the owner's triage; each bug's track (reported, triaged, reproduced, fixed, on main, replied, released); suggestions with the owner's decision; and what each release fixed. Its tabs are Triage, Bugs, Suggestions, Released, Log and Decisions.
- **What the owner does:** triages each report with Fix it, Accept, Reject, Close, Answer it or Ask the agent.
- **What agents do:** `room.py sync`, or `watch` every five minutes, reads GitHub and git and writes the board. Fix it starts an agent for that bug alone, which reproduces it, fixes it in a worktree of its own, pushes through the push gate and replies with the cause, the fix and the release. Accepted suggestions go onto the roadmap, and once a release is out, each report it fixed gets a reply saying so.
- **Its rule:** nothing is fixed, answered, closed or added to the roadmap until the owner says so on the board.

## The blog room

Where every redlamp.app post is tracked from idea to announcement. [Skill](../.cursor/skills/redlamp-blog/SKILL.md), [template](../.cursor/skills/redlamp-blog/template.tsx) and [room.py](../.cursor/skills/redlamp-blog/room.py).

- **What it shows:** the posts that are live; the pipeline (idea, promised, collecting, facts ready, drafting, draft); each post's kit for announcing it, with its card as a still, a GIF and an MP4, the X and LinkedIn copy and alt text; and a record of everything posted and where. Its tabs are Overview, Posts, Pipeline, Posted, Log and Decisions.
- **What the owner does:** publishes posts, posts each share himself, and marks it as posted, scheduled or not posted.
- **What agents do:** gather a post's facts with their sources, write the post, make its card in the house style and its copy in the owner's voice, and keep the record.
- **Its rule:** nothing is recorded as posted on less than the owner's mark, his word or a link.

## The press room

Where every outlet Redlamp is pitched to (newsletters, Mac and photography sites, developer and open-source communities, lists and directories) is tracked from finding it to its coverage. [Skill](../.cursor/skills/redlamp-press/SKILL.md) and [template](../.cursor/skills/redlamp-press/template.tsx).

- **What it shows:** each outlet with its way in (email, form, post, pull request or listing), its wave (now, with the write-ups, later), its priority and why it's on the list; the pitch written for it; its status, from To do through Sent and Replied to Covered, Declined or No reply; replies and follow-ups due; and the pull requests to lists. Its tabs are Overview, Emails, Actions, Replies, Outlets, Pitches, Plan, Decisions, Log and Measurements.
- **What the owner does:** sends each email and fills in each form himself, from his own accounts.
- **What agents do:** find outlets and the address each publishes for tips, write and check the pitches, prepare Gmail drafts, and record replies and coverage through an outreach script that stays outside the repository.
- **Its rule:** contacts, pitches and replies stay on the owner's Mac. The repository holds the room's template, with none of them.

## Workstream canvases

Work that spans sessions, such as a feature, a research thread or a fix, keeps a workstream canvas of its own: its goal, its plan, what needs the owner, its decisions and a log ([skill](../.cursor/skills/workstream-canvas/SKILL.md)). A room is for something that never finishes, and a workstream canvas ends with its work. The press room began as one.

## Opening a room

In Cursor, on a Mac set up for Redlamp, ask an agent for the room ("open the release room"); the skill's description tells it which. If the room doesn't exist yet, the agent makes it from the template and fills it from the commands the skill lists. Rooms cost little to keep: canvas edits were under 1% of the cost of the agent work measured in October 2026 ([docs/working-with-agents.md](working-with-agents.md)).
