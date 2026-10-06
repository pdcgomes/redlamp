# Copy and hooks

The copywriter writes every word the promo shows and the words posted with it. They live in `video/src/<slug>/copy.ts`, so the words can change without touching a scene, and in the design doc's Hooks and Post copy.

## The hook

The first one or two seconds decide whether anyone sees the rest, and most feeds start a video with the sound off. So the hook is a line on screen over a picture that is already moving, on the very first frame: never a logo, a title card or a fade from black.

Write five, each with a short ID, and make the hook a prop of the composition (`hook: "charging"`), so each can be rendered and posted as its own variant while everything else stays the same. Ways in that suit the brand's voice:

| Pattern | Example from the star promo |
| --- | --- |
| Say what's about to happen | Hold on. It's charging. |
| Give an object a want | This lamp has a favour to ask. |
| Call the audience by name | Psst. Photographers. |
| Promise a payoff | Wait for it. |
| Give the ending away, sweetly | One click would make its day. |

Hooks to avoid: anything that shouts ("You won't believe"), a question the picture doesn't answer, a claim the README doesn't make.

## Words on screen

- One idea per line, at most two lines at once, about six words a line.
- Big: at least 60 px tall at 1080 px wide, and 80 to 100 px for the hook. Inter Display SemiBold in paper on the dark wall.
- On screen long enough to read twice: about 0.3 s a word plus half a second, and the ask for 3 seconds or more.
- Words arrive on the beat (`Words` with `mode="pop"`, started on a cue) and leave before the next line arrives in the same place.
- Nothing to be read inside the apps' safe zones ([editing.md](editing.md)).
- Plain words for a reader with no context: say what Redlamp is ("a free raw editor for the Mac") before asking for anything.

## The ask

Once in the picture (the sign, the badge) and once in words at the end, plainly: "Star Redlamp on GitHub", with the address as it's typed, `github.com/pdcgomes/redlamp`. Give the reason when there's room, because a reason makes the ask easier to say yes to: "Every star helps photographers find it."

## The brand's voice

Calm, plain and precise (`docs/brand/README.md`): no superlatives, no exclamation marks (the sign's "Please star us!" is the owner's own words and the one exception), British spelling, and only claims the README makes. Check every line against the README before it goes in.

## Post copy

Written into the design doc, one per platform, with the alt text:

- **TikTok, Reels and Shorts:** a first line that works as a second hook, then what Redlamp is, the ask and the address, then three to five hashtags people search (#photography #photoediting #lightroom #opensource #macos).
- **X:** two sentences and the full link.
- **LinkedIn and Facebook:** a short paragraph: what it is, why it exists, the ask, the link.
- **Alt text:** what happens in the video, in order, in plain sentences, for anyone who can't see it.
