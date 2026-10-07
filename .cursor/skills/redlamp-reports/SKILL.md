---
name: redlamp-reports
description: The reports room, where every report people file on GitHub (Report a Bug and Send Feedback from the app, and issues opened by hand) is followed from arrival to the release that ships its fix, in a canvas the owner triages from. A bug he marks Fix it gets its own agent chat that reproduces it, fixes it, pushes to main and replies on the issue with the cause, the fix and the release; a suggestion he accepts goes onto the roadmap, one he rejects is closed with his reason. Use when a bug report or feedback comes in, when triaging, fixing, answering or closing a report, applying the owner's triage decisions, replying to a reporter, after a release ships, or asking which reports are open, fixed or released.
---

# The reports room

Every report is followed in one canvas, the reports room: the reporter's own words, the owner's triage, each bug's agent and how far it has got, the fixes on main and the release each is expected in, and the suggestions with the owner's decision. The owner triages everything by hand for now; nothing is fixed, answered, closed or added to the roadmap until he says so on the board.

## Where

| What | Where |
| --- | --- |
| The room | `~/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/reports-room.canvas.tsx`, from [template.tsx](template.tsx). `room.py sync` writes its `DATA` block; edit only its `room` object (decisions and links). A change to the rendering goes into the template and the room together. |
| The owner's clicks | `reports-room.canvas.data.json` beside it, under `triage`: `{ "<n>": { "decision": "fix" \| "close" \| "accept" \| "reject" \| "answer", "at": "…", "reason"?: "…", "token"?: "…" } }`. Only the canvas writes it. |
| The room's notes | `~/.cursor/projects/Users-pedrogomes-src-darkroom/reports-room/`: `reports/<n>.json` per report (what agents record), `log.jsonl`, `thumbs/`. Written only through `room.py`, so agents working at once never write the same file. |
| The script | [room.py](room.py): `status`, `sync`, `watch`, `claim`, `note`, `log` (its docstring has every option). Run the main checkout's copy, from anywhere. |
| The bug agent's brief | [bug-agent.md](bug-agent.md), which Fix it hands each bug's agent |
| How reports are filed | `packages/RedlampUI/Sources/Feedback` (the sheet and Your Reports), `web/lib/feedback.ts` (the relay), `.cursor/rules/tracker-issues.mdc` (Issues people file) |

Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first edit of the room. Link the room in every reply that changes it: `[Reports room](/Users/pedrogomes/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/reports-room.canvas.tsx)`.

## Every time: know where things stand

1. **Run `python3 .cursor/skills/redlamp-reports/room.py status`.** Never take states from memory. It lists the reports waiting for triage, the decisions waiting to be applied, the agents at work, and the closed ones, with each one's commits on main and branches, the release it's expected or was released in, and the replies. It folds in the owner's clicks.
2. **Write a read of each report waiting for triage** when the owner asks for one (Refresh, or Ask the agent): what the person says happened, the code it's likely about, whether main has fixed it since their version, whether something already tracks it. Two or three sentences, with no GitHub writes and no code changes: `room.py note <n> --read "…"`.
3. **Give each suggestion a proposal**: what Accept would do. A new row (its ID, the next free one in the right section of `docs/research/research-tracker.md`, its item text and phase), `follows` an existing row, or a `duplicate` of one: `room.py note <n> --proposal '{"kind": "new row", "id": "TON-31", "text": "…", "phase": "P3"}'`.
4. **After a release ships**, see After a release below.
5. **Sync**: `room.py sync`, and say plainly what you didn't check.

## Triage: what each button does

The owner decides on the Triage tab. Each card shows the report's own sections (What happened, What I expected, Steps to reproduce; What I'd like to do; Message), its area, how often, the version and Mac, the replies, a thumbnail of the first screenshot, a read and a proposal when an agent has written them.

- **Fix it** (bugs): records `fix` with a token and opens a new chat for that bug alone, prompted to follow [bug-agent.md](bug-agent.md). The agent claims the report with the token, which ties the chat to the board.
- **Accept** (suggestions): records `accept`; its label says what the proposal does.
- **Reject…** (suggestions) and **Close…** (bugs, questions): record `reject` or `close` with the owner's reason, in a sentence written for the reporter.
- **Answer it** (questions): records `answer` and opens a chat that answers it (Questions, below).
- **Ask the agent**: opens a chat to look into the report and write a read; it changes nothing.
- **Apply decisions**: opens one chat that carries out every recorded Accept, Reject and Close (Applying decisions, below). **Undo** removes a click that hasn't been applied.
- **Refresh**: opens a chat that brings the room up to date, as above.

A Fix it that no agent has claimed shows under "Fix it, no agent has picked it up yet", with Start its agent again.

## Applying decisions

Take each recorded decision in turn, then record it with `room.py note <n> --triage <decision> --applied "<what you did>"` (and `--tracked <ID>` where it became one), so the board stops showing it as waiting.

- **Close** (a bug): reply with the owner's reason, in his voice, and close it as not planned (`gh issue close <n> --reason "not planned"`).
- **Reject** (a suggestion): the same; add a `SKIP-` row to the tracker when the reason is worth keeping (section 13, Recorded skips).
- **Accept, a new row**: add the row to the tracker, as `.cursor/rules/tracker-issues.mdc` says: a new ID in the right section, never reused; Decision `Accepted (<date>): the owner accepted it from #<n>`; Status `Not started`; Source linking the issue. Start the issue's title with the ID (`gh issue edit <n> --title "TON-31: …"`), so the next sync adopts it and keeps the reporter's text above its block. Then bring the README roadmap and the Lightroom comparison into step (`scripts/roadmap-sync.py`, `.cursor/rules/roadmap-and-comparison.mdc`), commit, push, and sync the issues (`scripts/tracker-issues.py`, then `--apply`) only when `.cursor/rules/main-branch.mdc` allows it. Reply to the reporter: it's on the roadmap as the row, and the app's Your Reports shows it as Tracked as that ID.
- **Accept, follows a row**: label it `follows:<ID>` (create the label the first time, `gh label create follows:<ID> --color ededed`), and reply that it's tracked as the row (link its issue) and that the reply will come there when it lands. It stays open for the person who asked.
- **Accept, a duplicate**: close it as a duplicate of the row's issue, with a reply that links it.

## Questions

**Answer it** gives a question to a chat of its own. Answer from what the README, the docs, the manual and the code say, in the owner's voice, and close the issue as completed once it's answered. If the answer is "not yet" and it's worth doing, record what you found with `--waiting you`, so the owner can make it a suggestion; if it describes a bug, say so and let the owner triage it again.

## A bug's agent

Its brief is [bug-agent.md](bug-agent.md): claim, read, reproduce when it isn't obvious, fix in a worktree of its own, push to main through the push gate, reply with the cause, the fix and the release, and close. It records every step with `room.py note` and syncs the room, so the Bugs tab shows each bug's track: Reported, Triaged, Reproduced (or not needed), Fixed, On main, Replied, Released. It stops and asks, flagged on the board, when the fix would change how existing edits render, when another session is rewriting the same code, while the release room is approved or releasing, and when it needs something only the owner has.

The expected release is the upcoming version from `scripts/release-status.py`, or the one after it when the release room has already checked a candidate that doesn't hold the fix. A fix that changes nothing in the app (the site, the cask, the docs) is out once it's on main.

## After a release

When a release has shipped (`room.py status` shows fixes Released in it), reply on each report it fixed, in a sentence: "Redlamp 0.2.6 is out with this fix: Check for Updates… in the Redlamp menu installs it." Record it with `room.py note <n> --out-url <the comment's URL>`. A fix the room expected in that release but which isn't in it shows as missed: reply with a correction naming the release it comes in now, and record the new one in `--release`. The release room's last step brings this room up to date.

## Keeping it live

`room.py watch` syncs every 5 minutes (`--every <seconds>`); it only reads GitHub and git, so the owner can leave it running in a Terminal tab, or an agent in a background shell. A sync rewrites the room only when something changed, or when its last check is over four minutes old. A sync takes about a minute on this Mac, most of it git.

## Writing in the owner's voice

Replies on GitHub go out under the owner's account. Take his voice from his own messages (`~/.cursor/projects/Users-pedrogomes-src-darkroom/agent-transcripts/*/*.jsonl`, the user lines) and his comments on the issues: plain, first person, short, and kind to the person who took the time to report. Say what was wrong and what changed in words a photographer follows, not the code's. No superlatives, exclamation marks or em dashes, and none of the usual tells ("delve", "seamless"). British spelling (`docs/brand/README.md`). Claim only what the fix and its tests show.

## Later

When the owner wants it, a keeper chat can start each bug's agent without the click: `room.py watch` notices the new report, and the keeper hands a background agent the same brief.

## Evolving the room

The owner shapes the room as needs come up. A new list, state or button goes into the template, `room.py` and this skill in the same change, and the room picks it up. Commit them on main: `Reports room: …`.
