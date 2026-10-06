---
name: redlamp-promo-studio
description: The promo studio, which makes Redlamp's short promotional videos for social feeds the way a small creative agency does - a brief, hooks and copy, a script on a music grid, visuals from the promo kit, the edit, an original score written in code, review and delivery - with the owner approving at set points. Knows the kit's primitives (the lamp's light, the GitHub badge, the sign on its rope, the camera), the sound library, the review tools and the platforms' formats. Use when making, changing or reviewing a promo, teaser, social video or short film for Redlamp, or writing its hooks, script, score or post copy.
---

# The promo studio

Redlamp's promos are built in code in `video/` (Remotion, React and TypeScript), with scores synthesised in Python, so every frame and every sound can be changed, re-timed and rendered again in each shape. The studio is the way a job goes through that: each stage has a role, a deliverable and a file it owns, and the owner approves at three points. The first job was the star promo ([design](../../../docs/plans/2026-10-06-star-promo.md)); copy its files to start a new one.

A promo here is short (7 to 20 seconds), asks for one thing, and has to work in a feed: it stops the scroll in its first second, carries its message with the sound off, rewards the sound on, and loops. The roles' files say how.

## The roles

| Role | Delivers | Owns | Guide |
| --- | --- | --- | --- |
| Producer | The brief, the job's canvas, the schedule, delivery | The design doc's Brief; the canvas | [brief.md](brief.md), [delivery.md](delivery.md) |
| Creative director | The concept, and the call between options | The design doc's Concept | [brief.md](brief.md) |
| Copywriter | Five hooks, every word on screen, the ask, the post copy and alt text | `src/<slug>/copy.ts`; the doc's Hooks and Post copy | [copy.md](copy.md) |
| Scriptwriter | The beat sheet on the music grid | `src/<slug>/cues.json`; the doc's Script | [script.md](script.md) |
| Art director and animator | The scenes, from the kit | `src/<slug>/*.tsx`, new pieces in `src/kit/` | [visuals.md](visuals.md) |
| Editor | Pacing, the camera, each shape's layout, the loop | The composition's layouts and camera keys | [editing.md](editing.md) |
| Composer and sound designer | The score and every sound effect, in sync | `scripts/<slug>-score.py`, new sounds in `scripts/synth.py` | [sound.md](sound.md) |
| Reviewer | The storyboard sheet, the checks, the review notes | The doc's review notes | [review.md](review.md) |

One agent can play every role in turn, as the star promo was made. For a bigger job, the director writes the brief and the beat sheet, then runs the copywriter, the animator and the composer as parallel subagents, each given its guide and told the files it owns; the cue sheet only changes through the director, because all three work from it.

## The job, start to finish

1. **Open the job.** A workstream canvas (`.cursor/skills/workstream-canvas/SKILL.md`), the design doc at `docs/plans/<date>-<slug>-promo.md` from [brief.md](brief.md), and, if other sessions are committing to `main`, a worktree of its own (AGENTS.md has the commands; `video/` needs only `node_modules` and `public/film` cloned).
2. **Brief and concept.** Goal, audience, platforms, length, the one message, the ask, what the brand requires. One to three concepts; the director picks one and says why in the canvas's decisions.
3. **Hooks, words and script.** Five hooks, the lines, the ask, and the beat sheet with every cue on the grid. *Owner checkpoint 1: the script.* It's the cheapest stage to change, so put it in Needs you with the hooks and the beat sheet, and carry on building unless the owner wants to see it first.
4. **Build.** The scenes and the score, both from `cues.json`. Render stills as you go (`npm run review`), and look at them.
5. **Edit and fit.** Each shape's layout and framing, the safe zones, the pacing, the loop.
6. **Review.** The storyboard sheet for every shape, the checklist in [review.md](review.md), and the fixes. *Owner checkpoint 2: the cut, in Remotion Studio,* with the command to open it in Needs you.
7. **Deliver.** *Owner checkpoint 3: approve the render.* Then render every cut and its poster, and write the post copy beside them ([delivery.md](delivery.md)). Record the result a week after posting in the design doc.

## Where everything is

| Path | What |
| --- | --- |
| `video/src/kit/` | The promo kit: the music grid, a seeded random source, the camera, the brand's light (charge, shot, sparks, hit, aura), the lamp, the GitHub badge, the sign on its rope, a cursor, safe zones, the storyboard sheet ([visuals.md](visuals.md) lists them) |
| `video/src/components/` | The explainer's pieces the kit reuses: `Lens` (the app icon's lamp in SVG), `Words` in `Kinetic.tsx` (kinetic type), `Grain` in `Stage.tsx` |
| `video/src/theme.ts` | The brand's colours and Inter, loaded before the first frame |
| `video/src/<slug>/` | A promo: `cues.json`, `copy.ts`, its composition |
| `video/src/Root.tsx` | Every composition; each promo in a `Folder` of its own |
| `video/scripts/synth.py` | The sound library: instruments, effects, sidechain, reverb, loudness, mastering ([sound.md](sound.md)) |
| `video/scripts/<slug>-score.py` | A promo's score, written from its `cues.json` into `public/<slug>/` |
| `video/scripts/review.mjs`, `storyboard.mjs` | Stills at chosen frames or every cue; the storyboard sheet |
| `video/scripts/<slug>.mjs` | A promo's renders into `out/<slug>/` |
| `docs/brand/README.md`, `docs/brand/star-nudge.md` | The brand's rules, and the nudge the kit's light and sign come from |

## Commands

From `video/`:

```bash
npm run studio                                                    # Remotion Studio: every promo, scrubbable, with its props
python3 scripts/star-score.py                                     # a promo's score
npm run review -- StarPromo9x16 0,165,180 --out=/tmp/r --scale=0.5  # stills
npm run storyboard -- StarPromo9x16 --cues=src/star/cues.json --score=star/score.json
ffmpeg -i public/star/score.wav -af ebur128=peak=true -f null -  # loudness, as the platforms measure it
npm run star                                                      # the renders, after the owner approves
```

`mise run video` opens Studio from anywhere in the repository, and `mise run video -- star` renders.

## Rules every role keeps

- **The brand** ([docs/brand/README.md](../../../docs/brand/README.md)): the red is light with a source and moves rather than multiplies; one light per picture; lit from above left; no bright point in the lens. The voice is calm, plain and precise, with no superlatives and no exclamation marks, except "Please star us!", which the owner wrote; every claim is one the README makes. A promo may be playful in what happens; the words stay plain.
- **One cue sheet.** Every timing is a beat in `cues.json`, read by the composition and the score alike. Nothing is timed by hand in one and not the other.
- **Every frame stands alone.** Remotion renders frames in parallel tabs and in any order: no `Math.random`, no state carried from one frame to the next, no CSS animations ([visuals.md](visuals.md) has the rest).
- **Only what's verified** goes in the canvas and the doc: loudness from the meter, frames you rendered and looked at.
- **Licences.** Original music and sound only, from `synth.py`; Inter (SIL OFL, bundled); GitHub's mark unaltered, only to point at the repository.
