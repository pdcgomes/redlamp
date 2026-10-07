---
name: redlamp-blog
description: The blog room, where every redlamp.app blog post is tracked from idea to announcement in a canvas the owner marks as they post. It covers the posts that are live, the ones in the pipeline, each post's kit for announcing it (its card as a still, a GIF and an MP4, the X and LinkedIn copy, alt text) and a record of what has been posted where. Makes a post's card in the house style and writes its copy in the owner's voice. Use when writing, publishing or announcing a blog post, making its tweet, LinkedIn post or card, looking for a post's images or promo material, or asking what's been posted or what the blog does next.
---

# The blog room

Every blog post is tracked in one canvas, the blog room: the posts that are live, the ones in the pipeline, each post's kit for announcing it, and a record of what has been posted where. The owner keeps it open to find a post's card and copy, and marks each share as it goes out. A post's material lives in the repository, never only in `/tmp` or in another worktree's `build/`, which is where the first cards were lost.

## Where

| What | Where |
| --- | --- |
| The room | `~/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/blog-room.canvas.tsx`, from [template.tsx](template.tsx). Edit only its `room` object; `room.py thumbs` writes its `THUMBS`. A change to the rendering goes into the template and the room together. |
| Posts | `web/content/blog/<slug>/index.md`, with its images beside it (`web/README.md`, The blog; the checks and capture script are in `.cursor/skills/redlamp-site/SKILL.md`) |
| A post's kit | `docs/blog/social/<slug>/`: `card.json` (the card's words) and `posts.md` (the X and LinkedIn copy, what to attach, alt text, and where each went), committed; `card.png`, `card.gif`, `card.mp4` and `thumb.jpg`, rendered and gitignored |
| Copies to post from | `~/Downloads/redlamp-<slug>.png`, `.gif` and `.mp4`. macOS keeps Downloads from Cursor: agents can write there but not list or read it, and the room opens the kit's own copies instead. |
| Facts for a post not yet written | `docs/blog/facts/<slug>.md`, each fact with its source |
| The card | [card/card.html](card/card.html) and [card/render.py](card/render.py) |
| Where things stand | [room.py](room.py) `status` |

Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first write to the room. Link the room in every reply that changes it: `[Blog room](/Users/pedrogomes/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/blog-room.canvas.tsx)`.

## Every time: know where things stand

1. **Read the owner's marks first.** The room keeps them in `blog-room.canvas.data.json`, beside it, under `needsYou` (`{ "<id>": { "state": "done" | "skipped" | "asked", "at": "…" } }`) and `shares` (`{ "<share id>": { "state": "posted" | "scheduled" | "draft" | "skipped", "at": "…" } }`, where `draft` is the owner's Not posted). Never write that file. Fold each mark into `room`: the share's `state` and `when`, a row in `posted` that says it rests on the owner's mark, and the channel's status line in the kit's `posts.md`. A Needs you item that names the share then shows as done by itself. When the owner gives a post's address on the platform, it goes in the share's `link` and the `posted` row.
2. **Run `python3 .cursor/skills/redlamp-blog/room.py status`.** Never take dates or states from memory. It lists the posts on main with their dates, drafts and whether redlamp.app serves them; each kit's files; the fact sheets; and blog files that are only on another branch or uncommitted in a worktree.
3. **Bring the room up to date in the same turn:** `summary`, `upNext`, `needsYou`, `posts`, `pipeline`, `posted`, a `log` entry and `updated`. Say plainly what you didn't check.

## Writing a post

1. For a post about work still under way, gather the facts first into `docs/blog/facts/<slug>.md`, each with its source. Put the post in `pipeline` with its stage: `idea`, `promised` (a post already says it's coming), `collecting`, `facts ready`, `drafting` or `draft`.
2. Write it as `web/README.md` (The blog) describes, in a worktree of its own when other sessions are committing to `main`. Its images go beside `index.md`; a canvas is captured with `.cursor/skills/workstream-canvas/capture.py`.
3. The owner publishes it, or says to. Once it's live, move it from `pipeline` to `posts`, and make its kit.

## Announcing a post: its kit

1. **The card's words** go in `docs/blog/social/<slug>/card.json`. `title` is the post's title in lines broken at phrases, two or three of them. `subtitle` is two plain sentences in the owner's voice: a fact from the post, then "This is how I …". `titleSize` (128 pixels by default) only when three lines don't fit. A `[bracketed]` part of the subtitle is picked out in white; the owner prefers none (5 October). `eyebrow` and `url` default to "From the blog" and "redlamp.app/blog".
2. **Render it.** Make the venv its docstring gives, then `/tmp/rl-card/bin/python .cursor/skills/redlamp-blog/card/render.py docs/blog/social/<slug> --still` and look at `card.png`. Then render it all with `--downloads`, which takes a minute or two, and look at a few of the GIF's frames as well. It stops when a line runs past the margins or the text comes within 40 px of the lockup, and warns when the GIF is over the 5 MB X allows from a phone.
3. **The copy** goes in `posts.md`, laid out as the existing kits are:
   - **X:** it opens with "Redlamp is a free, open-source raw editor for the Mac that works like Lightroom.", the owner's line, so people who don't know Redlamp have the context. Then a plain line on what the post is about, then "New post: …" and the link. Under 280 characters, counting a link as 23 (count with code, not by eye), with an alternative. No hashtags, emoji or exclamation marks.
   - **LinkedIn:** longer and in the first person, in short paragraphs: what Redlamp is, the problem the post takes on and what it shows, the link, and a question to close. About 150 to 200 words. It takes `card.mp4`, which LinkedIn plays, or `card.png`.
   - **Alt text** for the card, and the post's own images that would work as a second picture.
4. **In the room:** the post's `shares`, word for word from `posts.md`, each with an ID (`x-<slug>`, `linkedin-<slug>`); `upNext` set to the post; a Needs you item for each share, naming it in `share` so the item takes the share's buttons; then `python3 .cursor/skills/redlamp-blog/room.py thumbs`.

## Recording what's posted

`posted` lists everything posted to announce Redlamp or a post, newest first: the blog's shares and the rest, such as Reddit, Product Hunt or a promo. Each row says what it rests on: a link, the owner's mark, his word in a chat (with the chat's ID), or only a draft. A share that was planned or scheduled but never confirmed is `unconfirmed`, with a Needs you item asking. Nothing is recorded as having gone out on less than the owner's word or a link.

## Writing in the owner's voice

The site's prose is largely agent-written, so take the owner's voice from his own messages in the agent transcripts (`~/.cursor/projects/Users-pedrogomes-src-darkroom/agent-transcripts/*/*.jsonl`, the `"role":"user"` lines), not from the posts. He writes plainly, in the first person, with phrases such as "a bunch of", "essentially", "Ideally" and "to be honest", and short sentences for emphasis. No em or en dashes, no superlatives the README doesn't make, and none of the usual tells ("delve", "seamless", "game-changer", "unlock", a closing moral). British spelling (`docs/brand/README.md`). He has turned copy down as "too AI slop-py"; when in doubt, write it plainer.

Claim only what the post or the README says, checked against them.

## Evolving the room

The owner shapes the room as needs come up. A new list, state or button goes into the template and this skill in the same change, and the room picks it up. Commit both on main: `Blog room: …`.
