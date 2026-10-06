# Delivery

The producer renders once the owner has approved the cut, writes the posting notes, and later records what came of it.

## Rendering

Each promo has a render script, `video/scripts/<slug>.mjs` (copy `star.mjs`), run as `npm run <slug>` and added to `mise/tasks/video`. It:

- Reads anything live the promo shows when it renders (the star promo's count from the GitHub API), and stops if it can't, rather than render a stale number.
- Writes the score if it's missing.
- Renders every shape into `video/out/<slug>/` as H.264 at CRF 16, 4:2:0, BT.709, with 320 kbps AAC at 48 kHz, which every site and player reads the same way, and a JPEG poster for each.
- Checks every frame it wrote for a blank, white frame (`renderUntilPainted` in `scripts/blank.mjs`), renders the file again if it finds one, and stops after three tries rather than deliver a flash ([visuals.md](visuals.md) says why they happen).
- Takes `--hook=<id>` or `--hooks` for variants, and `--draft` for a half-size preview.

In the agent sandbox, run it with `NODE_USE_ENV_PROXY=1` so its own request reaches GitHub; the script keeps that setting away from Remotion, whose requests to its own server on localhost would otherwise go to the proxy and stall the encode.

Name files `<promo>-<shape>[-<hook>].mp4`, as `star-redlamp-9x16-psst.mp4`. Outputs aren't committed.

## The platforms

| Platform | Shape | Notes |
| --- | --- | --- |
| TikTok | 9:16 | Choose the cover in the app; post the caption and hashtags from the design doc. |
| Instagram Reels and Stories | 9:16 | Reels can share to the feed; Stories need the ask well clear of the reply bar. |
| Instagram and Facebook feeds | 1:1 or 4:5 | |
| YouTube Shorts | 9:16 | Choose the thumbnail from the video's frames. |
| X | 1:1 or 9:16 | The first frame often shows as the preview, which is why it carries the hook; the link goes in the post. |
| LinkedIn | 1:1 | The longer post copy. |

Lengths, sizes and caption limits change; check a platform's current limits before posting a promo made for it. The masters are made to −14 LUFS, about the level YouTube plays audio at, so no platform has to turn them up.

## Posting

- One variant at a time on a platform, a few days apart, so each hook's numbers can be read.
- The caption's first line is a second hook; the address is in the caption, or the profile's link where captions can't carry one.
- Alt text where the platform takes it.
- Original audio: name it (for example "Redlamp: charging") so others can use it.

## Results

A week after posting, add to the design doc's Results: the goal's number before and after (stars on the repository, from `https://api.github.com/repos/pdcgomes/redlamp`), and what each platform reports: views, average watch time or completion, replays, shares, profile visits. Note which hook ran where. The next brief starts from what worked.
