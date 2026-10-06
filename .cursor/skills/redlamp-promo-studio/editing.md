# The edit

The editor owns the promo's timing as it plays: the camera, each shape's layout and framings, how long things stay on screen, and how the end runs into the start. The edit happens in the composition's layout tables and camera keys, not in a timeline: change a number, render stills, look.

## Pacing

- Something changes every one to two seconds: a line, a camera move, an event. A held shot needs motion inside it (the tremble, the swing).
- Cut and move on cues. A camera move starts or lands on a beat; an impact gets a zoom punch and a shake on its frame.
- Hold what must be read: the ask for at least three seconds.
- The gap before the drop is a half-beat of stillness in the picture too (the squash), then the release.

## The camera

- Push in slowly to build tension (a steady creep, `(k) => k`), pull back fast to release it and show the whole action.
- Frame the action, not the layout: the star promo is close on the lamp while it charges, wide for the shot's arc, close on the badge for the sign and the click, and wide again for the end card.
- Nothing half in frame by accident: check each framing's edges for an object cut through. Move the object in the world or the framing, not both.
- Ease every move (`framing()` eases in and out unless a key says otherwise); zoom eases in log space so pushes and pulls feel even.

## Shapes and safe zones

One timeline, laid out for each shape. Lay out 9:16 first: it's the most constrained, and the most watched.

| Shape | Size | Where it plays | Keep words and the ask |
| --- | --- | --- | --- |
| 9:16 | 1080 × 1920 | TikTok, Reels, Shorts, Stories | Below the top 260 px, above the bottom 480 px, left of the right-hand 160 px from 700 to 1600 px down |
| 1:1 | 1080 × 1080 | Feeds | 60 px in from every edge |
| 4:5 | 1080 × 1350 | Instagram and Facebook feeds | 60 px in from every edge |
| 16:9 | 1920 × 1080 | YouTube, X, Reddit | 60 px in; captions sit above the player's bar |

The composition's `guides` prop draws the 9:16 zones in Studio (`SafeZones.tsx`). They're conservative across the apps; check an app's current overlay when a promo is made for one platform.

## The loop

Feeds loop short videos, and a replay is a second view. End so the start follows on:

- The last bar's sound leads into the first frame (the star promo's hum rises again to where it starts), and the final 30 ms fade so the loop doesn't click.
- The first frame is already moving, so the cut back to it reads as a new beat rather than a restart.

## The first frame and the poster

The first frame is often the thumbnail where a platform shows one: it carries the hook line and a picture that's clearly about to do something. Choose a poster frame for platforms that let you pick a cover: the one that says the ask in a single picture (the star promo uses the sign hanging under the badge, frame 300).
