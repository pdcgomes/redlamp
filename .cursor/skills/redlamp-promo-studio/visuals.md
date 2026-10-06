# Visuals: art direction and animation

The art director and animator build the scenes in `video/src/<slug>/` from the promo kit in `video/src/kit/`, and add to the kit anything the next promo could use. Everything on screen is drawn in code: no stock footage, no screen recordings unless the promo is about the app (then use `scripts/capture-promo.sh`, as Introducing Redlamp does).

## The brand in motion

From `docs/brand/README.md` and `docs/brand/star-nudge.md`:

- **The red is light with a source.** Every red thing comes out of the lamp and goes somewhere. Never a flat red fill or a red background.
- **One light per picture.** Light moves rather than multiplies: what gathered behind the lamp leaves with the shot, and the lamp dims as its light goes. The wall is warm near-black (`color.wall`), lit only by the light that's there.
- **No bright point in the lens.** A glowing lens with a bright centre is HAL 9000's eye. The lens brightens evenly; the shot leaves from behind the tile's top edge.
- **Lit from above left.** Paper is lighter at its top left; steel catches light on its upper edge.
- **Physical materials.** Steel, bakelite, ruby glass, paper, rope.

## The kit

| Module | What it gives you |
| --- | --- |
| `grid.ts` | `grid(cueSheet)`: frames per beat and bar, `at(beat)`, `cue(name)`, `seconds(beat)`; `onBeats()` for a flare on each beat |
| `random.ts` | `random(seed)`: the same numbers in every tab, every time |
| `camera.ts` | `framing(frame, keys)` eases between framings (zoom in log space; a key can name its own easing); `shake()` for impacts; `cssTransform()` and `canvasMatrix()` so DOM layers and canvases move together; `toScreen()` |
| `LightCanvas.tsx` | A canvas the size of the frame, drawn every frame in world space through the camera |
| `light.ts` | The brand's light, from the website's star nudge: a `Charge` (`backlight`, `motes`, `chargeLevel`, `squashLevel`), an `arc()` path, a `Shot` (`beam`, `headAt`), `sparks` (`burst`, `shotSparks`, analytic flight), `strike` and `aura` round a pill, `ripple`, `pool` (light on the wall), and `keyframes()` |
| `Lamp.tsx` | `Lamp`, the app icon's lamp on its tile; `lampPose()`: knocks that shake it (one per hit of a drum roll), the squash, an aim towards its target, and the recoil; `glowScale()` |
| `GitHubBadge.tsx` | The website header's GitHub button on its own, with its star and count: `badgeSize()`, `badgeParts()` (where the star is and where a rope ties on), `formatCount()`, `GitHubMark`, `StarGlyph` |
| `rope.ts`, `Sign.tsx` | The website's sign on its rope (`web/lib/hanging-sign.ts`, unchanged): `performSign()` simulates a scripted performance once (the drop, an anchor that moves, hands that grab and throw) and caches every frame; `fallTime()` so a catch can land on a beat; `Sign` and `signSize()` draw it |
| `Cursor.tsx` | A pointer that reads on the dark wall and on paper, with a press |
| `SafeZones.tsx` | Where the apps' own interface covers a vertical video; the `guides` overlay for Studio |
| `Storyboard.tsx` | The storyboard sheet ([review.md](review.md)) |
| `measure.ts` | `textWidth()`, to size shapes round their words before layout |

From elsewhere in `video/src`: `Lens` (`components/Lens.tsx`), `Words` (`components/Kinetic.tsx`, kinetic type that pops or rises word by word on springs), `Grain` (`components/Stage.tsx`), and `color` and `font` (`theme.ts`).

## How a scene is put together

The star promo (`src/star/StarPromo.tsx`) is the pattern:

- **A world and a camera.** Objects sit in world units (the frame's pixels at zoom 1). A camera eases between named framings, pushes in for tension, pulls back for release, and punches and shakes on impacts.
- **Layers, back to front:** the wall; a `LightCanvas` for light behind objects (the glow on the wall, the charge); the objects in a DOM layer under the camera's CSS transform; a second `LightCanvas` for light in front (the shot, sparks, the hit); a pointer layer; words in screen space; the vignette and grain; the safe-zone guides when asked for.
- **Worked out once.** Anything expensive or stateful for a shape (the sign's physics, the motes' paths, the sparks) is computed once per shape and cached in a module-level map, keyed by what it depends on.
- **Each shape has a layout**: where the objects are, and the camera's framings, in one table per shape.

## Motion

Playful motion is the old animation principles, timed to the grid:

- **Anticipation:** the charge, the tremble, the squash before the shot, the lamp turning to aim.
- **Squash and stretch, overshoot and settle:** springs (the badge's swell is the website's 1, 1.15, 0.96, 1.04, 1), `springs.pop` for words.
- **Follow-through:** the rope and the sign; sparks that slow in the air and fall.
- **Secondary action:** motes, rays, the light round the badge.
- **On the beat:** arrivals land on cues; things that bounce bump on the kick (`onBeats`).

## Rules for Remotion

Remotion renders frames in parallel browser tabs and in any order, so each frame must come out the same from nothing but its frame number:

- No `Math.random`, `Date.now` or state carried between frames: seed randomness with `kit/random.ts`.
- Physics and anything stateful are simulated from the start, once per tab, and cached (`kit/rope.ts`).
- No CSS animations or transitions; derive every value from `useCurrentFrame()`.
- Canvases draw in `useLayoutEffect`, in software (`getContext("2d", { willReadFrequently: true })`, as `LightCanvas` does). A GPU canvas can be captured before it's painted: on the star promo, a tab's first frame lost its canvases, once its whole background.
- Don't hold frames with `requestAnimationFrame` inside `delayRender`: it stalls in the CLI's parallel tabs and hung a render.
- Importing from `web/` works (the sign's physics comes from `web/lib/hanging-sign.ts`) for modules that import nothing from the site.
- After any change to a layer, render frame 0 on its own and in sequence (`npm run review -- <id> 0` and `1,0`) and look at both.
