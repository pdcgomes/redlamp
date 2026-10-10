#!/usr/bin/env python3
"""
A feature video's score (src/features/FeatureVideo.tsx): the episode's own track
(scripts/features/music/<episode>.py), or E01's theme (scripts/features-theme.py) for an episode
without one yet, with the episode's own sounds on the frames their pictures land on. The
sounds come from the episode's board (scripts/features/boards/<episode>.py, sounds()), which times them
on the series' cue sheet as it times the picture.

    python3 scripts/features-score.py --episode e01                     # public/features/e01/score.wav
    python3 scripts/features-score.py --episode e01 --arrangement pulse

It writes every arrangement as score-<arrangement>.wav, so they can be compared against the picture
(the composition's `score` prop), and the chosen one as score.wav, which the cut plays: synthwave, the
series' (docs/plans/2026-10-10-feature-videos.md, Sound). Beside them it writes score.json,
the chosen score's level at every frame for the storyboard sheet, and cues.json, the cue sheet with
every sound on screen added as a cue, for scripts/score-report.py. Each arrangement is written from
the bar before the episode's first frame, its lead-in, which goes over the end of the opener's sound:
opener.wav beside score.wav, and opener-<arrangement>.wav beside each of the others. Needs numpy,
Pillow and pixelkit (the boards draw with it).
"""

import argparse
import contextlib
import importlib.util
import io
import json
import sys
from copy import deepcopy
from functools import cache
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import synth as s  # noqa: E402
from features import world as w  # noqa: E402


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


theme = load(w.VIDEO / "scripts/features-theme.py", "features_theme")


def music(key):
    """The episode's own track, or E01's theme for an episode without one; a variation (e01-photo) plays
    its episode's."""
    base = key.split("-")[0]
    path = w.VIDEO / f"scripts/features/music/{base}.py"
    return load(path, f"music_{base}") if path.exists() else theme

CLICK_UP = 0.07
# The whole video's loudness, as the platforms measure it, in LUFS.
TARGET = -14.0
# The limiter's ceiling, a little under the platforms' -1 dBFS, which its soft knee can overshoot.
CEILING = -1.2


def press(velocity):
    """A mouse button going down and held: the first half of a click."""
    return s.click(velocity)[: int(CLICK_UP * s.SR)]


def release(velocity):
    """The button coming back up: the click's second half."""
    return s.click(velocity)[int(CLICK_UP * s.SR):]


def rising(velocity):
    """Four soft blips climbing A major a sixteenth apart, an octave over the arpeggio, as a mask's
    overlay fills: C sharp, E, F sharp and A, the notes of E02's A13 under it."""
    step = int(round(theme.BEAT / 4 * s.SR))
    run = [s.blip(note, velocity, 0.07, duty=0.5) for note in (85, 88, 90, 93)]
    out = np.zeros(step * (len(run) - 1) + len(run[-1]))
    for i, tone in enumerate(run):
        out[i * step : i * step + len(tone)] += tone
    return out


# Each kind of sound on screen: what plays, how loud, and how much of it goes to the room.
SOUNDS = {
    "press": (lambda: press(0.8), 0.2, 0.05),
    "release": (lambda: release(0.8), 0.15, 0.05),
    "tick": (lambda: s.tick(0.6), 0.16, 0.08),
    "key": (lambda: s.key(0.9), 0.36, 0.06),
    "key up": (lambda: s.key(0.8, up=True), 0.28, 0.06),
    "flip": (lambda: s.tick(0.7), 0.2, 0.1),
    "fill": (lambda: rising(0.7), 0.25, 0.2),
}


FILM_SCORE = w.VIDEO / "scripts/score.py"


@cache
def film_opening():
    """
    The opener's sound at the film's level, and the short cut's whole score: Introducing Redlamp's
    opening as scripts/score.py writes it in the short cut, sample for sample, for the opener's first
    `scene` bars, then its last chord held to the opener's end, as the looks explainer and the app's
    welcome hold it, with an air swell up into the episode's first hit. score.py is run as a full run of
    it goes, the film cut first and then the short cut, without its own loop over the cuts and with its
    write() caught, so nothing of the film's is written. The held chord is the same scene drawn again
    from where the short drew it, in its room and at its level, and takes over in the 50 ms before the
    scene's last bar line.
    """
    source = FILM_SCORE.read_text()
    film = {"__name__": "introducing_score", "__file__": str(FILM_SCORE)}
    exec(compile(source.split("\ncuts = json.loads(", 1)[0], str(FILM_SCORE), "exec"), film)
    cuts = json.loads((w.VIDEO / "src/introducing/cuts.json").read_text())
    scene, bars = cuts["short"][0]
    assert (scene, bars) == ("safelight", w.OPENER["scene"]), f"the short opens on {bars} bars of {scene}, not the opener's"
    held = (w.OPENER["bars"] - bars) * w.SHEET["beatsPerBar"]
    film["SCENES"]["features-hold"] = {8: ([("Dadd9", 8)], [0, 0]), "piano": None, "cues": [("swell", 0), ("swell", held)]}
    written = {}
    film["write"] = lambda path, x: written.__setitem__(Path(path).stem, x)
    with contextlib.redirect_stdout(io.StringIO()):
        film["fresh"]()
        room = film["score"]("film", cuts["film"])
        drawn = deepcopy(film["rng"]), dict(film["_cache"])
        room = film["score"]("short", cuts["short"])
        film["rng"], film["_cache"] = drawn
        film["score"]("features-opener", [["safelight", bars], ["features-hold", 2]], room)
    short, out = written["score-short"], written["score-features-opener"].copy()
    bar, cross = int(round(bars * w.SHEET["beatsPerBar"] * 60 / w.OPENER["bpm"] * s.SR)), int(0.05 * s.SR)
    out[: bar - cross] = short[: bar - cross]
    blend = np.linspace(0, 1, cross)[:, None]
    out[bar - cross : bar] = short[bar - cross : bar] * (1 - blend) + out[bar - cross : bar] * blend
    return out[: int(round(w.OPENER_FRAMES / w.FPS * s.SR))], short


def opener(episode, lead):
    """
    The opener's sound, as far below the episode's score as the short's opening sits below the rest of
    the short, with the arrangement's lead-in (`lead`, its seconds before the episode's first frame)
    over its end: the held chord eases down to half under it and fades out over the last three frames,
    where the episode's first hit comes in.
    """
    sound, short = film_opening()
    n = int(round(w.OPENER["scene"] * w.SHEET["beatsPerBar"] * 60 / w.OPENER["bpm"] * s.SR))
    head, after = short[:n], short[n:n + len(episode)]
    gap = s.loudness(after) - s.loudness(head)
    out = sound * 10 ** ((s.loudness(episode) - gap - s.loudness(head)) / 20)
    under = len(lead)
    out[-under:] *= (1 - 0.3 * np.linspace(0, 1, under) ** 1.5)[:, None]
    ramp = int(round(3 / w.FPS * s.SR))
    out[-ramp:] *= np.linspace(1, 0, ramp)[:, None]
    out[-under:] += lead
    return out


def on_screen(events):
    """Puts the episode's sounds, (beat, kind, pan), on an arrangement's effects bus."""

    def sounds(fx):
        for beat, kind, pan in events:
            sound, gain, wet = SOUNDS[kind]
            fx.add(theme.at(beat), sound(), gain=gain, pan_to=pan, wet=wet)

    return sounds


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--episode", required=True)
    parser.add_argument("--arrangement", help="the arrangement the cut plays; the track's first unless given")
    args = parser.parse_args()
    key = args.episode.lower()
    track = music(key)
    arrangement = args.arrangement or next(iter(track.ARRANGEMENTS))
    if arrangement not in track.ARRANGEMENTS:
        sys.exit(f"{key}'s track has no arrangement called {arrangement}: choose from {', '.join(track.ARRANGEMENTS)}")
    board = load(w.VIDEO / f"scripts/features/boards/{key}.py", f"board_{key}")
    if not hasattr(board, "sounds"):
        sys.exit(f"{key}'s board has no sounds() yet, so its score can't be written.")
    events = board.sounds()
    unknown = sorted({kind for _, kind, _ in events} - set(SOUNDS))
    if unknown:
        sys.exit(f"{key} has sounds this script can't play: {', '.join(unknown)}")

    out = w.VIDEO / "public/features" / key
    out.mkdir(parents=True, exist_ok=True)
    for name, arrange in track.ARRANGEMENTS.items():
        buses, mastering = arrange(sounds=on_screen(events))
        # The last 1.6 s fade out with the picture, as the last chord dies away. What's mastered to the
        # target is the whole video, opener and all; the opener is the quieter, so the score sits a
        # little above the target.
        target = TARGET
        for _ in range(2):
            mastered = s.master(buses, seconds=theme.PRE + theme.TOTAL, target=target, ceiling=CEILING, fade=1.6, **mastering)
            lead, each = theme.split(mastered)
            head = opener(each, lead)
            target += TARGET - s.loudness(np.concatenate([head, each]))
        s.write(out / f"score-{name}.wav", each)
        s.write(out / f"opener-{name}.wav", head)
        whole = np.concatenate([head, each])
        print(f"    score-{name}.wav: {s.loudness(each):.1f} LUFS; with opener-{name}.wav, {s.loudness(whole):.1f} LUFS, "
              f"true peak {s.true_peak(whole):.1f} dBFS")
        if name == arrangement:
            mix, intro = each, head
    s.write(out / "score.wav", mix)
    s.write(out / "opener.wav", intro)

    per = s.SR // w.FPS
    frames = len(mix) // per
    rms = np.sqrt((mix[: frames * per] ** 2).mean(axis=1).reshape(frames, per).mean(axis=1))
    (out / "score.json").write_text(json.dumps({"fps": w.FPS, "arrangement": arrangement,
                                                "level": [round(float(x), 4) for x in rms / rms.max()]}))
    counts = {}
    cues = dict(w.CUE)
    for beat, kind, _ in events:
        counts[kind] = counts.get(kind, 0) + 1
        cues[f"{kind.replace(' ', '-')}-{counts[kind]}"] = beat
    chords = w.SHEET["chords"] if track is theme else track.CHORDS
    (out / "cues.json").write_text(json.dumps({**w.SHEET, "chords": chords, "cues": cues}, indent=1))
    print(f"==> public/features/{key}/score.wav ({arrangement}, {theme.TOTAL:.1f} s, {s.loudness(mix):.1f} LUFS, "
          f"true peak {s.true_peak(mix):.1f} dBFS, {len(events)} sounds on screen)")


if __name__ == "__main__":
    main()
