---
name: redlamp-social
description: The social room, where Redlamp's Instagram and TikTok posting is run like a small agency in a canvas the owner approves from. It holds the schedule, what each feature video covers, its two images, the captions and alt text, and each post's state on each platform, with the roles of strategist, producer, copywriter, scheduler, community and analyst. Use when working on social media, Instagram, TikTok or Reels, the feature videos, a post's caption, hashtags or schedule, posting, comments, results or followers.
---

# The social room

Redlamp's Instagram and TikTok posts are run from one canvas, the social room, the way a small agency runs an account: a calendar, a video for each post made in the promo studio, captions written to the copy rules below, and each post's state on each platform. The owner approves every cut and every post in the room before it goes out. The first campaign is ten feature videos, one feature each, posted from Tuesday 27 October 2026.

Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first edit of the room. Link the room in every reply that changes it: `[Social room](/Users/pedrogomes/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/social-room.canvas.tsx)`.

## Where

| What | Where |
| --- | --- |
| The room | `~/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/social-room.canvas.tsx`, from [template.tsx](template.tsx). Edit only its `room` object: `room.py room` writes its POSTS block and `room.py thumbs` its THUMBS block. |
| The owner's marks | `social-room.canvas.data.json`, beside the room: his answers to Needs you, his approvals, and each TikTok post's state and link. Only the canvas writes it; agents never do. |
| The schedule | `docs/social/posts.json`: the episodes, the posts with their times, platforms, captions and alt text, and the standard caption lines |
| The campaign | `docs/plans/2026-10-10-feature-videos.md`: the format, each episode's hooks, beat sheet, captions and alt text, and the source of each claim |
| Storyboards | `video/out/features/boards/`: `<episode>.png` is the sheet, and `<episode>-hook.png` and `<episode>-result.png` are the two frames the room shows. They are rendered, not committed, so `room.py` takes a board from the main checkout or another worktree when this one hasn't got it. |
| The owner's photos | `~/src/redlamp-social/photos/`, outside the repository, which agents can read (they can't read `~/Pictures` or `~/Downloads`). Each photo keeps its `.redlamp` sidecar, so a result is the owner's edit. |
| The publisher's records | `~/src/redlamp-social/state/`: what was posted, its links and numbers. No tokens. |
| Renders | `~/src/redlamp-social/renders/`, one file per post, named by its `file` (`e01-a.mp4`), outside every worktree. The publisher uploads from it, and the owner opens it in Finder for a TikTok sitting. |
| Tokens and app secrets | The macOS Keychain, and nowhere else |
| Where things stand | [room.py](room.py) `status` |

## Every time: know where things stand

1. **Read the owner's marks first**, in `social-room.canvas.data.json`. Never write that file.
   - `needsYou`: `{ "<id>": { "state": "done" | "skipped" | "asked", "at": "…" } }`. Fold each into `room.needsYou` as `.cursor/skills/workstream-canvas/SKILL.md` describes.
   - `cut:<episode>`: `{ "state": "approved" | "held", "at": "…" }`. An approved cut moves the episode's `stage` to `approved` in posts.json. A held one stays `in review`, with a Needs you item asking what to change.
   - `post:<post id>`: `{ "state": "approved" | "held", "at": "…", "caption": "…" }`. An approval keeps the caption it approved, and stands only while the post's caption is the same; the room asks for it again after a change.
   - `tiktok:<post id>`: `{ "state": "scheduled" | "posted" | "skipped", "at": "…" }`, and `link:<post id>:tiktok`, the post's address on TikTok once he gives it.
   - `null` is a mark he took back with Undo.
2. **Run `python3 .cursor/skills/redlamp-social/room.py status`.** Never take dates or states from memory. It checks posts.json, lists each episode's boards and renders, says whether the room's schedule and images are up to date, and gives the next three posts due.
3. **Bring the room up to date in the same turn:** `summary`, `status`, `needsYou`, `plan`, a `log` entry and `updated` (ISO, with the offset). After a change to posts.json, run `room.py room`; after new boards, `room.py thumbs`. After each edit, the `Canvas TypeScript check` line in the tool result must report no errors. Say plainly what wasn't checked, such as renders `status` couldn't read, or anything on Instagram or TikTok you didn't see.

The room's plan is the campaign plan's todos, one step for each with the todo's ID, and a step changes status in the same turn as its todo (`.cursor/skills/workstream-canvas/SKILL.md`, A plan's todos are its steps).

## The roles

One agent can play every role in turn.

- **Strategist:** keeps the calendar in posts.json and plans each flight of four videos. At each weekly review, reads the results and decides what to keep, change or drop, and records why in the room's Decisions.
- **Producer:** has every video built in the promo studio (`.cursor/skills/redlamp-promo-studio/SKILL.md`) from the campaign's beat sheet. The owner reviews each cut in Remotion Studio and approves it in the room with Approve cut before it renders. An episode's `stage` is `storyboard`, `building`, `in review` (from which Approve cut shows), `approved` or `rendered`.
- **Copywriter:** writes the hooks, the end lines, the captions, the hashtags, the alt text and the replies to comments, to the copy rules below.
- **Scheduler:** for Instagram, the publisher posts each approved post at its time. For TikTok, the scheduler puts each sitting in Needs you with the posts it covers, and the owner schedules them in TikTok Studio.
- **Community:** reads the comments on both platforms and drafts a reply in the room to each one that needs it. A reply is sent only once the owner has approved it.
- **Analyst:** records each post's views, watch time, likes, shares, saves and follows at 48 hours and at 7 days, Instagram's from its API once the publisher reads them and TikTok's from a TikTok Studio screenshot the owner sends. Records the release downloads per day as well, from the download counts the GitHub API gives for each release's assets (`gh api repos/pdcgomes/redlamp/releases`).

## Copy rules

The owner asked for these on 10 Oct 2026: simple and direct, nothing that reads as written by AI, nothing whimsical, and a clear call to action, so that people understand at once what they're shown.

- Every line says what is on screen or what the viewer gets.
- At most two lines are on screen at once, and a line has at most 17 characters.
- No wordplay or puns, characters talking, metaphors, rhetorical questions, "not X, it's Y" constructions, triplets for rhythm, em or en dashes, exclamation marks, emoji or superlatives.
- None of these words: seamless, effortless, unlock, elevate, game-changer, magic, level up, supercharge, revolutionary, ultimate.
- Every video ends with DOWNLOAD FREE / REDLAMP.APP (`standard.endCard`).
- A caption is one sentence on what the video shows, then the standard lines in posts.json (`about`, what Redlamp is; `cta`, the call to action, with "link in bio"; `requirements`, with "early development"), then 3 to 5 hashtags. A video that names another company's product says that Redlamp isn't affiliated with it, before the hashtags.
- Claims come only from the README or `docs/lightroom-comparison.md`, and each episode's `source` names where.
- British spelling (`docs/brand/README.md`).

`room.py status` checks what a script can: the line lengths, the dashes, exclamation marks, emoji and words above, the standard lines and the hashtags. The rest is read by eye; when in doubt, write it plainer.

## The calendar

- Tuesdays and Fridays at 18:00 London time, on Instagram and TikTok the same day.
- Two days later, the post's second hook goes out as an Instagram trial reel (`"trial": "MANUAL"`), which only non-followers see. It reaches followers only if the owner shares it.
- The cuts for each flight of four videos are approved by the Friday before the flight starts: 23 October, 6 November and 20 November for the first campaign.
- TikTok sittings: one per group of four posts if TikTok Studio's scheduling window allows it, otherwise one a week.
- Times in posts.json are ISO, with the offset. London is on +00:00 from 25 October 2026 to 28 March 2027, and `status` warns about an offset that doesn't match the time zone's.

## Posting

- **Nothing posts unless the owner has approved both its cut and the post in the room.** Agents never post by hand, on either platform.
- **Instagram** is posted by the publisher: `room.py publish`, and `room.py tick`, which a launchd agent runs every 15 minutes to publish the approved posts that are due, read the numbers and comments, update the room and turn a failure into a Needs you item. Neither is built yet. `auth`, `publish`, `sync` and `tick` come next, with `room.py auth instagram` run by the owner in his own terminal. Until then, nothing goes to Instagram.
- **TikTok** is scheduled by the owner in TikTok Studio on the web, from the captions in the room. He marks each post Scheduled, then Posted with its link.

## What the platforms allow

Read from their developer documentation on 10 Oct 2026.

- **Instagram:** its API publishes Reels to professional accounts, with a caption, a cover and an audio name. It takes a resumable upload from the Mac, so no public server is needed. It posts trial reels, with graduation `MANUAL` or `SS_PERFORMANCE`. It allows 100 API-published posts in a moving 24 hours and has no scheduling of its own, so the publisher posts each post at its time. It needs a Meta app with the account in a role.
- **TikTok:** its Content Posting API restricts the content that unaudited clients post to private viewing. Its Content Sharing Guidelines say "Not acceptable: A utility tool to help upload contents to the account(s) you or your team manages", and it caps posts at about 15 a day per creator. So TikTok is scheduled by hand.

## Secrets

Tokens and app secrets live only in the macOS Keychain. Never print them, and never put them in the repository, the room, its data file or a chat.

## Evolving the room

The owner shapes the room as needs come up. A change to the rendering goes into the template and the room together, and into this skill when it changes what the room shows or what the owner marks. A new field in posts.json goes into the template's types and `room.py`'s checks first, because `room.py room` writes only a schedule that passes its checks. Commit them together: `Social room: …`.
