# Generative Remove on hard scenes (RM-21)

Why Generative Remove fails on water, building fronts, railings and tiled ground, traced to each cause, and what the cheap fixes do, measured on 1 November 2026 on INF-14's hard cases (`research/benchmarks/removal.json`, group `hard`, and the large cases where they show the same failures). Every number here is from `research/benchmarks/results/removal-2026-11-01.json`; the prototypes are on the branch `rm-20/fill-prototypes`. "Evidence" is what was measured or read; "Assessment" is judgement ([conventions](_conventions.md)).

## Summary

- **Most failures come in through the reference.** Generative Remove shows the model the photo with the spot already filled by content-aware fill, and the model copies its reference closely (RM-10). Where content-aware fill copies the wrong thing (sky, windows, a kiosk, shards of brick joints, bits of the ducks), the generative fill copies it too: on six of the eight hard cases (the ducks, the ferry, the trunk, the leaves, the railing and the windows) and two of the five large ones (the car and the wall) the generative fill shows content-aware fill's mistake in the same place.
- **What the reference or the photo still suggests comes back.** Ghosts of the ducks in content-aware fill's water became two new ducks; the branches above a removed trunk brought a trunk back; a sliver of the ferry's sign left outside a first, narrower brush was drawn again, larger.
- **Without a reference the model makes a blank.** On all seven hard cases tried, no reference gave a white or black slab, or a glowing blob (PSNR against the truth from −3.0 to 2.4 dB on the composites, against 6.5 to 27.6 dB with today's reference): the inverse of the crop's highlight roll-off turns the model's near-white into highlights far above the photo's.
- **A softened reference fixes structure on most of them.** Content-aware fill blurred inside the spot (the `softened` reference RM-10 kept for judging) carried the railing and the stone wall's window through the spot (railing 8.9 to 15.5 dB, building windows 6.5 to 15.7 dB), kept the open water as good as today's (27.6 and 27.3 dB), removed the ferry with the hill's outline whole, laid the paving's joints straight, and left no duck on the water, only a dark smudge where the mallard was; but it brought the tree trunk back, since its dark smear and the branches above both suggest one.
- **More context helps where the reference doesn't mislead it.** A crop holding four times the spot on a coarser level raised all three composites (water 27.6 to 29.4 dB, railing 8.9 to 15.1, windows 6.5 to 11.0), at a level's loss of resolution, which RM-20's detail transfer would give back. More steps and a wider crop on the same level changed only the windows.
- **Fix plan:** a reference that carries no copied content (the spot filled smoothly from its edge, which the softened reference approximates) first; then guard the fill's highlights and suggestions (the spot grown over what's left of the thing, and over its reflection on water for brushed spots); then a crop of four times the spot, on a coarser level, once RM-20's detail transfer is in; then content-aware fill refined coarse to fine with the same detail transfer (RM-12). More steps are not worth their time.

## The cases

All CC0 from raw.pixls.us, each licence read from its repository listing (`https://raw.pixls.us/json/getrepository.php?set=all`, "publicdomain/zero/1.0", 1 November 2026), and each file checked against the SHA-256 the listing gives.

| Case | Scene | Photo (raw.pixls.us getfile) | Spot |
| --- | --- | --- | --- |
| `7d2-ducks` | Water, four ducks and their reflections | Canon EOS 7D Mark II, 7023 (the look-development duck sample) | Find's birds, each with its reflection (RM-13) |
| `s22-ferry` | Water, a shoreline and a hill behind the ferry | Samsung Galaxy S22 Ultra, 6625 | A brush over the ferry |
| `80d-trunk` | A brick building front with windows behind a tree trunk | Canon EOS 80D sRAW2, 1296 (fixture) | A brush up the trunk |
| `g95d-leaves` | Wet paving bricks in perspective, two leaf inlays | Panasonic DC-G95D, 6334 | A brush over the two leaves |
| `composite-water` | Open water below a shoreline | Samsung Galaxy S22 Ultra, 6625 | The pasted object, across the shore's line |
| `composite-railing` | A metal railing beside steps and a doorway | Fujifilm X100VI, 7302 | The pasted object, over the railing |
| `composite-windows` | A modern building front: windows, panels, cladding | Sony UMC-R10C, 7540 | The pasted object, over a window and panels |
| `composite-facade` | A stone church front, an arched window | Fujifilm X100VI, 7302 | The pasted object, over the window's edge |

The composites are made by `research/prototypes/generative/make_removal_composites.py` (an object cut from the Nikon D7500 sample, 1531, pasted onto a crop of the photo at full resolution, written as a linear DNG with the crop as the truth). The large cases (`d7500-car`, `r6m2-van`, `composite-paving`, `composite-grass`, `composite-wall`) are RM-20's.

## Method

Each case was removed through the prototype CLI (`redlamp render … --dump-areas`), which fills as `main` does unless told otherwise, with:

- **content-aware Remove** (RM-07 at process 20), and **today's Generative Remove**: the reference filled from the photo, the prompt `remove`, four steps, seed 0;
- **other references:** `softened` (content-aware fill blurred inside the spot, twice over 24 texels), `none`, and `generated` (the spot filled by the model itself at half the crop's resolution without a reference, then shown as the reference);
- **a wider crop:** `context-wider` holds up to four times the spot's size at the same level (at most 1024 pixels), and `context-coarser` four times on whatever level that fits;
- **more steps:** eight instead of four (`steps-8`).

`research/prototypes/generative/score_removal.py` scores each spot at full size in linear camera RGB: on the composites, PSNR against the truth inside the spot and the PSNR of its low-pass (a Gaussian of 4 pixels), which judges structure apart from texture; on every case, the seam and the detail against the photo around the spot. The real photos have no truth, so what is said about them comes from looking at them at 100% beside the photo. Times are under a load average of 31 to 86, with two other agents on the Mac's GPU.

## Failure classes and their causes

### 1. Content-aware fill's mistakes, copied through the reference

Evidence:

- **The car** (`d7500-car`): content-aware fill fills the drive with sky, a wall and a bush; today's generative fill is a clean drive, but a bush and a pale wall patch stand where content-aware fill put them.
- **The trunk** (`80d-trunk`): content-aware fill copies the kiosk's glazing into the trunk; the generative fill keeps a tall pale panel where the glazing was.
- **The ferry** (`s22-ferry`): content-aware fill copies the shore's buildings over the hill in blocks; the generative fill removes the ferry, but the hill's outline steps where one of the blocks did.
- **The leaves** (`g95d-leaves`): content-aware fill breaks the brick joints into shards; the generative fill draws the same broken joints, smoother.
- **The railing, the wall and the windows** (composites): content-aware fill copies a patch of sky into each; the generative fill keeps the sky in the railing and the wall, and turns the windows' into a blank white panel (PSNR 6.5 dB, below content-aware fill's 8.3).
- **The water** (`composite-water`): content-aware fill's water is plausible, and so is the generative fill's (27.6 dB, against 27.0).

Assessment: the model doesn't repair its reference; it refines it. RM-12's blocks and RM-07's wrong sources are the generative fill's problem whenever they're in the reference, which is why RM-10 found that the photo itself as the reference brings the car back. The reference has to carry the scene's colours and light without carrying content.

### 2. Things suggested come back

Evidence:

- **The ducks**: content-aware fill leaves grey ghosts of the mallard and vertical streaks (RM-12); the generative fill turns two of the ghosts into whole new ducks, one on the water and one in its reflection.
- **The trunk**: with the softened reference, whose dark smear runs where the trunk was, and the branches above running into the spot, the model draws a new trunk.
- **The ferry**: a first brush left a sliver of its sign outside the spot, and today's fill drew the whole sign again, larger; with the brush widened, a smaller sliver is left, and every method keeps it as it is.

Assessment: the model completes what its surroundings and its reference imply, and "remove" doesn't stop it. Two causes: object-shaped blobs in the reference (content-aware fill's ghosts, the softened reference's smear), and remnants outside the spot (the sign, a duck's reflection, a branch that only makes sense with a trunk). The first is the reference's; the second needs the spot to reach what's left.

### 3. No reference, a blank

Evidence: with no reference, every hard case tried came back as a slab or a blob: white over the ferry, a glowing pink blob over the windows and the railing, white and black over the trunk, white slabs and dark duck shapes over the ducks, grey over the paving, a sunlit glare over the composite's water. PSNR on the composites fell to −3.0 (windows), −0.8 (railing) and 2.4 dB (water).

Assessment: the crop is shown to the model scaled so its mean sits at a quarter, with its highlights rolled off (`x / (1 + x)`), and its fill is brought back through the inverse, so the model's near-white becomes 30 (at an encoded 0.95) to 800 times (at 1) the crop's mean: a blank becomes a glare. Without a reference the model leans on the prompt, and the `remove` prompt's embedding appears to favour an empty, bright surface. RM-10's earlier finding that no reference "invents things" (a covered car, a lawn) was with the `empty` and `background` prompts.

### 4. Lines and repeating structure

Evidence: with a clean reference the model carries lines and repeats: under the softened reference the railing's bars run straight through the spot and the stone wall's window is completed with its frame (15.5 dB, low-pass 16.4); under the generated reference the window is completed and one bar bends (16.1 dB). The paving's rows come through today's fill at the coarse fill's resolution (RM-20). What a wider crop does is in the table below.

Assessment: on these cases the model can carry lines and repeats; what breaks them most is the reference's patchwork. A crop showing more around the spot helps too, even with today's reference (the coarser crop, below).

### 5. Softness on coarse levels, and grain

Large spots are filled on level 1 or 2 and look soft beside the photo: RM-20 and its design ([sharp fills](../../plans/2026-11-01-sharp-fills-design.md)). On the composites, which Redlamp opens as linear DNGs and whose noise it measures from the image, the fill's added grain is a fifth to two thirds of the photo's.

### 6. A brushed spot's shadow and reflection

Evidence: brushed over the ferry, today's first fill (with a brush that missed the waterline) left the ferry's reflection as a dark smudge on the water. RM-13 takes a thing's shadow and reflection with it only when it is picked by a click or found, not brushed.

## The cheap fixes, measured

On the composites (PSNR against the truth, and its low-pass, in dB):

| Composite | Content-aware | Today | Softened | Generated | None | Wider crop | Coarser crop | 8 steps |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `composite-water` | 27.0 (29.9) | 27.6 (30.5) | 27.3 (30.6) | 26.3 (28.4) | 2.4 (3.7) | 27.6 (30.5) | 29.4 (32.2) | 27.0 (29.4) |
| `composite-railing` | 8.5 (8.8) | 8.9 (9.1) | 15.5 (16.4) | 16.1 (17.0) | −0.8 (−0.7) | 8.9 (9.1) | 15.1 (15.7) | 9.1 (9.3) |
| `composite-windows` | 8.3 (8.8) | 6.5 (6.7) | 15.7 (17.2) | 12.1 (12.7) | −3.0 (−2.8) | 14.8 (16.0) | 11.0 (11.6) | 15.0 (16.4) |

The wider crop changes nothing where the crop already held 1024 pixels at 2.5 times the spot (the water and the railing give the same fill to the pixel); the coarser crop fills on a coarser level (the railing's, the windows' and the ferry's from level 1 to 2, the water's from 0 to 2), so its fill is softer, which PSNR penalises little. Every figure is one seed's (0); the windows' spread, 6.5 to 15.7 dB, shows how far one seed can move on a case where the reference misleads.

On the real photos (what each looks like at 100%):

| Method | Ducks | Ferry | Trunk | Leaves |
| --- | --- | --- | --- | --- |
| Content-aware | Grey ghosts of the ducks, vertical streaks | The shore's buildings copied over the hill in blocks | The kiosk's glazing copied into the trunk | The joints broken into shards |
| Today | Two new ducks, one in the reflection | The ferry gone; the hill's outline steps where content-aware fill's block did | A tall pale panel where the glazing was | The shards, smoothed |
| Softened | No duck; soft streaks, a dark smudge where the mallard was | The ferry gone; the hill's outline continuous | A new trunk | Straight joints in perspective |
| Generated | Dark smudges, a bright slab in the reflection | A white haze over the hill | A new trunk, with ivy | Orange cracks across the bricks |
| None | White slabs, dark duck shapes | A white slab | A white slab and a black one | A grey slab |
| Wider crop | not run | As today | As today | As today |
| Coarser crop | not run | As today | not run | not run |
| 8 steps | not run | As today | As today | As today |

The ferry's brush left a sliver of its sign outside the spot, which stays under every method.

Times (seconds for one fill, and the load average):

| Method | Seconds a fill, median (range) | Cases | Load |
| --- | --- | --- | --- |
| Today | 82 (36 to 181) | 8 | 49 to 69 |
| Softened | 59 (49 to 111) | 7 | 42 to 63 |
| Generated | 74 (36 to 132) | 7 | 31 to 51 |
| None | 36 (22 to 144) | 7 | 32 to 68 |
| Wider crop | 71 (58 to 83) | 6 | 34 to 52 |
| Coarser crop | 56 (26 to 68) | 4 | 55 to 72 |
| 8 steps | 114 (78 to 131) | 6 | 33 to 56 |

The loads differ between rows (they ran one after another while other agents' work came and went), so only large differences mean anything: no reference halves the transformer's tokens, eight steps double its steps, and the generated reference adds a fill at half the resolution (a quarter of the tokens, without a reference).

Assessment, fix by fix:

- **Softened reference:** the best on structure, at no cost; its smear can suggest the thing removed (the trunk), so it is a step, not the end.
- **No reference:** never; it makes blanks.
- **Generated reference:** as good as softened on the railing, worse on the composite's water (26.3 dB against 27.3) and on the real photos (a haze over the ferry's hill, cracks across the paving, slabs on the ducks' water), since the fill it starts from has no reference either; it adds that fill's time, about a tenth more (a quarter of the pixels, no reference).
- **Wider crop, coarser crop, more steps:** the wider crop changed only the one composite whose crop wasn't already 1024 pixels (the windows, 6.5 to 14.8 dB), and none of the real photos by eye; eight steps helped the windows (15.0 dB) and nothing else, for twice the time; the coarser crop helped all three composites (water 27.6 to 29.4 dB, railing 8.9 to 15.1, windows 6.5 to 11.0), since four times the spot's size shows the model the whole railing and shoreline, but it fills a level coarser and so softer: worth it only with RM-20's detail transfer to bring the detail back.

## What RM-12's coarse-to-fine refinement would need

RM-12 tried twice to keep content-aware fill's texture at full size and left its blocks (its row records both). RM-20's detail transfer is the missing part: take content-aware fill's working-level result as the guide and copy its detail at full size, matching each block's low-pass to the guide's and its overlap to what is placed, from an exhaustive search on the GPU. That replaces the blocks and the doubled copies of blending four moves with straight-cut blocks of the photo's own texture. It doesn't fix what content-aware fill copies wrongly at the working level (the sky in the drive, the ducks' ghosts): that needs RM-13's reflection regions kept out of the candidates and, for the generative fill, a reference that doesn't depend on content-aware fill at all.

## Fix plan, in order

1. **A reference without copied content** (`generativeDefaults`, `generativeCrop`): the spot filled smoothly from its edge, a membrane interpolation of the photo around it on the crop's level (harmonic, so it brings colours and light from the rim and no shapes), blended into the photo as the softened reference is. It keeps what softened gained on structure, and has no smear to suggest the thing removed. Measure it on these cases against softened before it becomes the default; content-aware fill then stays the reference for spots small enough to be filled at full size, where RM-07's texture is right.
2. **Guards on what comes back** (`GenerativeCrop.fill`): a fill brighter than the brightest of the photo around it is clamped there, so a blank can't become a glare; and a brushed spot on water takes its reflection with it as picked ones do (RM-13's mirror region), with the spot grown over remnants at its edge (the Healing tool's growth for picks, 0.5% of the height).
3. **More context, then detail back** (`generativeCrop`): the crop holding four times the spot's size, on a coarser level when that's what fits in 1024 pixels, once RM-20's detail transfer brings the coarser fill back to the photo's resolution. Measure it with the reference of step 1, on more seeds than one.
4. **RM-12 with RM-20's detail transfer**: content-aware fill's blocks replaced by the photo's own texture at full size; one search serves both rows.
5. **Not worth it:** more steps (twice the time, a gain on one case of six), and a wider crop on the same level, which changes only crops not already 1024 pixels across.

## What wasn't measured

- The membrane reference of step 1; the highlight clamp of step 2.
- Lightroom's Generative Remove on the same cases: INF-14's bench task `removal-generative-remove-2026-11-01` waits for the owner.
- More than one seed per case: every number is seed 0's.
