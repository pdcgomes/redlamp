# Review

The reviewer checks the cut before the owner sees it, and again before it's rendered. An agent can't watch a video or hear a score, so every check here works from stills, sheets and numbers; the owner's own viewing in Remotion Studio is the review that decides.

## The tools

From `video/`:

| Tool | Command | For |
| --- | --- | --- |
| Stills | `npm run review -- <id> 0,165,180 --out=/tmp/r --scale=0.5`, or `--cues=src/<slug>/cues.json` for every cue; `--props='{"guides":true}'` | Looking at moments, and at consecutive frames for motion |
| Contact sheet | `ffmpeg -pattern_type glob -i '/tmp/r/*.jpg' -vf "scale=360:-1,tile=6x3" sheet.jpg` | Many stills in one image |
| Storyboard sheet | `npm run storyboard -- <id> --cues=src/<slug>/cues.json --score=<slug>/score.json` | Every cue's frame over the score's level: the whole script on one page |
| Safe zones | The `guides` prop, in Studio or in stills | Words clear of the apps' interface |
| Score report | `python3 scripts/score-report.py public/<slug>/score.wav --cues=src/<slug>/cues.json` | Loudness and true peak, the climb bar by bar, each cue's sound against its frame, the energy from sub to air ([sound.md](sound.md)) |
| Loudness | `ffmpeg -i public/<slug>/score.wav -af ebur128=peak=true -f null -` | The platforms' own measurement, to confirm the report's |
| Spectrogram | `ffmpeg -i public/<slug>/score.wav -lavfi showspectrumpic=s=1600x500:legend=1:fscale=log out.png` | The arrangement, without listening |
| Draft | `npm run <slug> -- --draft` | A half-size MP4 for a phone |

## The checklist

Picture:

- [ ] The first frame shows the hook line and doesn't give the payoff away; it renders right on its own and in sequence (`review -- <id> 0` and `1,0`).
- [ ] Every line reads at phone size: at least 60 px tall at 1080 px wide, on screen for about 0.3 s a word plus half a second; the ask for 3 s or more.
- [ ] No line arrives before the one in its place has gone.
- [ ] In 9:16, nothing to be read under the safe zones (`guides`).
- [ ] No object cut through by the frame's edge where the shot isn't moving.
- [ ] The brand: light with a source, one light per picture, no bright point in the lens, lit from above left.
- [ ] Words in the brand's voice, every claim from the README.
- [ ] Every hook variant fits (`--props='{"hook":"<id>"}'` at the hook's frames).

Sound and sync:

- [ ] −14 LUFS integrated, ±0.5, and a true peak at or under −1 dBFS, by ffmpeg.
- [ ] The build climbs into the drop, bar by bar, and the drop is the loudest bar (the score report).
- [ ] Each cue with a sound of its own lands within a frame of its picture (the score report), and the storyboard sheet agrees.
- [ ] The sub is about a third of the energy or less and the mids 15% or more, so it carries on a phone.
- [ ] It fits the owner's taste ([sound.md](sound.md)): dark and cinematic, unless the brief asks otherwise.
- [ ] In the encoded draft, the audio's offset from the score is 0 ms (cross-correlate their envelopes).

The loop and the file:

- [ ] Nothing drops away or stops dead: no gap in the waveform before the drop, and the end dies away and fades out with the picture.
- [ ] `npx tsc --noEmit` passes.

## Notes and the owner's review

Write what was checked, and what wasn't, into the design doc's review notes and the canvas's log, with the storyboard sheets. Then put the owner's review in Needs you, with the command:

```bash
cd ~/src/darkroom/video && npm run studio
```

and what to look at: the hook variants (the `hook` prop), the timing of the build, the drop, the ask's hold, and the sound on a phone.
