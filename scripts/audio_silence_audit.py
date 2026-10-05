#!/usr/bin/env python3
"""Count engine dropouts in an exported mix, cross-referenced against the sources.

A digital-silence run in the export is only a defect if NO source was silent
there. The project this audits is a screen capture of a mostly-silent room, so
a naive silence count reports the recording's own quiet passages as engine
faults — which is how a re-measurement would "confirm" a fixed bug or bury a
real one in noise.

For each silence run in the exported mix we therefore:

  1. map the run's timeline position back through the audio clips' own
     (timeline_start, source_start) pairs to a time in each source file,
  2. decode the source at that time and ask whether it is silent too.

A run the sources are silent across is FAITHFUL and reported separately. A run
the sources are not silent across is a DROPOUT, and is what fails.

Usage: audio_silence_audit.py <project.vyproj> <exported.raw> [exported.mp4] [grid_fps]

The grid rate is taken as the last argument when given. Do not derive it from the
sample count: the export is short by the tail padding this script also measures,
so a short export reports a high grid and every frame->source lookup lands late.
"""

import array
import json
import os
import subprocess
import sys

TIMEOUT = 600
# A run longer than this in the EXPORT is a dropout; shorter ones are sample-level
# transitions between clips, not holes. 4 ms is the threshold the original
# measurement used.
DROPOUT_MS = 4.0
# SILENCE_PEAK_FLOOR: the source peak (int16, so 32767 = 0 dBFS) at or below which
# a stretch counts as silent. 64 is about -54 dBFS -- below any speech or music a
# room recording picks up, and above the dither tail real "silence" sits on.
SILENCE_PEAK_FLOOR = 64
def load_project(path):
    import cbor2

    with open(path, "rb") as fh:
        return cbor2.load(fh)


def audio_segments(pf):
    """(timeline_start, source_start, asset_id, stream) for every audio clip.

    Segments overlap (the tracks are stacked duplicates of the same streams), so
    the caller only needs the set of (asset, stream, src_start) triples reachable
    at a given timeline position.
    """
    out = []
    for track in pf.get("tracks", []):
        for clip in track.get("clips", []):
            if clip.get("kind") != 1:  # kind 1 == Audio
                continue
            tl = clip.get("timeline_start_frame")
            src = clip.get("source_start_frame")
            ln = clip.get("source_length_frames")
            if tl is None or src is None or not ln:
                continue
            out.append((tl, src, tl + ln, clip.get("asset_id"), clip.get("stream_index")))
    out.sort()
    return out


def source_time(segs, tl_frame, grid_fps):
    """Recording time for a timeline frame, via the segment covering it."""
    best = None
    for tl, src, end, _, _ in segs:
        if tl_frame >= tl and tl_frame < end:
            if best is None or tl > best[0]:
                best = (tl, src)
    if best is None:
        return None
    tl, src = best
    return (src + (tl_frame - tl)) / grid_fps


def asset_index(pf):
    """Every asset, not just the ones the app classifies as audio.

    A screen recording is a VIDEO file with five audio streams inside it, and the
    audio clips reference it by its video asset id. Filtering to kind == 1 (the
    app's Audio classification) drops exactly the assets this audit exists to
    check, and every run then reports "source probe unavailable" — which reads as
    a pass. That is the failure mode where the audit cannot fail.
    """
    return {a.get("id"): a for a in pf.get("assets", []) if a.get("id") is not None}


def segments_covering(segs, tl_frame):
    return [s for s in segs if s[0] <= tl_frame < s[2]]


def silence_runs(samples, min_samples):
    runs = []
    start = None
    for i, s in enumerate(samples):
        if s == 0:
            if start is None:
                start = i
        elif start is not None:
            if i - start >= min_samples:
                runs.append((start, i - start))
            start = None
    if start is not None and len(samples) - start >= min_samples:
        runs.append((start, len(samples) - start))
    return runs


def source_peak(path, stream, t0, t1):
    """Peak |sample| of a source over [t0, t1), or None if it could not be read.

    A PEAK, not a zero count. The sources here are not bit-silent in their quiet
    passages: they carry a dither / denormal tail around -60 dBFS, so "every
    sample is exactly 0" is false for a genuinely silent stretch and a zero-count
    criterion reports the engine's silence as an engine dropout. The export's runs
    ARE exact zeros (nothing was written), so the honest comparison is the
    source's amplitude against a floor, not its zero pattern.
    """
    cmd = [
        "ffmpeg", "-v", "error",
        "-ss", f"{max(t0, 0.0):.3f}", "-t", f"{max(t1 - t0, 0.001):.3f}",
        "-i", path, "-map", f"0:a:{stream}",
        "-ac", "1", "-ar", "48000", "-f", "s16le", "-",
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT).stdout
    except subprocess.TimeoutExpired:
        # A probe we could not run must NOT read as "the source is silent", which
        # would excuse a real dropout.
        return None
    if len(out) < 2:
        return None
    a = array.array("h")
    a.frombytes(out[: len(out) // 2 * 2])
    peak = 0
    for v in a:
        av = -v if v < 0 else v
        if av > peak:
            peak = av
    return peak


def main():
    if len(sys.argv) < 3:
        print("usage: audio_silence_audit.py <project.vyproj> <exported.raw>", file=sys.stderr)
        return 2
    proj_path, raw_path = sys.argv[1], sys.argv[2]
    mp4_path = sys.argv[3] if len(sys.argv) > 3 else None
    grid_arg = sys.argv[4] if len(sys.argv) > 4 else None
    container_duration = 0.0
    if mp4_path:
        try:
            out = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "csv=p=0", mp4_path],
                capture_output=True, timeout=TIMEOUT, text=True,
            ).stdout.strip()
            container_duration = float(out)
        except (subprocess.TimeoutExpired, ValueError):
            container_duration = 0.0

    pf = load_project(proj_path)
    segs = audio_segments(pf)
    assets = asset_index(pf)
    if not segs:
        print("audio-audit: project has no audio clips -- fixture void", file=sys.stderr)
        return 1

    nbytes = os.path.getsize(raw_path)
    nsamples = nbytes // 2
    samples = array.array("h")
    with open(raw_path, "rb") as fh:
        samples.fromfile(fh, nsamples)
    if nsamples == 0:
        print("audio-audit: export carried no audio", file=sys.stderr)
        return 1

    # The grid rate is not in the project file (it saves 0.0 for "inherit"), so it
    # comes from the EXPORT's container duration. Deriving it from the sample count
    # instead is circular: the export is short by the very tail padding this audit
    # is also measuring, so samples/frames reports 60.0336 fps for a 60 fps project
    # and every frame->source lookup lands slightly late.
    start_f = pf.get("start_frame", 0) or 0
    end_f = pf.get("end_frame", 0) or 0
    # end_frame is EXCLUSIVE, not inclusive. render_start computes
    # nframes = end_frame - start_frame and sets render_job.end = end_frame - 1,
    # so a range of 0..1786 is 1786 frames. Reading it as inclusive made this
    # script report the export as "one frame short" against a 1787-frame range and
    # would have sent someone chasing a tail-padding defect that does not exist:
    # 1786 frames at 60 fps is exactly the 1428800 samples the export emitted.
    frames = end_f - start_f
    if grid_arg:
        grid_fps = float(grid_arg)
    elif container_duration > 0:
        grid_fps = frames / container_duration
    else:
        grid_fps = 0.0
    if grid_fps <= 0:
        print("[audio-audit] FAIL: no grid rate available; pass it or supply the mp4", file=sys.stderr)
        return 1
    print(
        f"[audio-audit] {nsamples} samples ({nsamples/48000:.3f}s), container {container_duration:.4f}s, "
        f"{frames} frames, grid {grid_fps:.4f} fps"
    )
    if abs(grid_fps - round(grid_fps)) > 0.01:
        print(f"[audio-audit] NOTE: grid rate is not a whole number ({grid_fps:.4f}); frame->source mapping is approximate")
    # The tail-padding measure, reported whether or not anything else fails: the
    # export must be exactly frames * samples-per-frame samples, and neither short
    # (audio ending before the picture) nor long (the file outlasting it).
    spf = 48000.0 / grid_fps
    want = int(round(frames * spf))
    if want != nsamples:
        print(
            f"[audio-audit] NOTE: length off by {nsamples - want:+d} samples "
            f"({(nsamples - want) / spf:+.3f} frames) against a {frames}-frame range"
        )
    else:
        print(f"[audio-audit] length exact: {nsamples} samples = {frames} frames")

    min_samples = int(DROPOUT_MS * 48)
    runs = silence_runs(samples, min_samples)
    print(f"[audio-audit] digital-silence runs > {DROPOUT_MS}ms: {len(runs)}")

    dropouts = []
    faithful = []
    unverified = []
    for start, length in runs:
        t_start = start / 48000.0
        t_end = (start + length) / 48000.0
        # Map the run's START, not its midpoint, and probe the run's own length
        # from there. Using the midpoint and then extending by the full run length
        # overshoots by half the run, so the probe window runs past the hole into
        # the audio after it -- finds samples there, and reports a faithful
        # passage as an engine dropout.
        run_sec = length / 48000.0
        start_frame = int(t_start * grid_fps)
        covering = segments_covering(segs, start_frame)
        if not covering:
            unverified.append((t_start, length, "no audio clip covers this span"))
            continue
        verdicts = []
        for tl, src, end, asset_id, stream in covering:
            asset = assets.get(asset_id)
            if asset is None:
                verdicts.append(None)
                continue
            st = source_time(segs, start_frame, grid_fps)
            if st is None:
                verdicts.append(None)
                continue
            verdicts.append(
                source_peak(asset["path"], stream or 0, st, st + run_sec)
            )
        known = [v for v in verdicts if v is not None]
        if not known:
            unverified.append((t_start, length, "source probe unavailable"))
        elif all(v <= SILENCE_PEAK_FLOOR for v in known):
            faithful.append((t_start, length, max(known)))
        else:
            dropouts.append((t_start, length, max(known)))

    for t, l, pk in faithful:
        print(
            f"[audio-audit]   faithful  {t:8.3f}s  {l/48:8.1f} ms"
            f"  (sources peak {pk}, under the {SILENCE_PEAK_FLOOR} floor)"
        )
    for t, l, why in unverified:
        print(f"[audio-audit]   UNVERIFIED {t:8.3f}s {l/48:8.1f} ms  ({why})")
    for t, l, pk in dropouts:
        print(
            f"[audio-audit]   DROPOUT   {t:8.3f}s  {l/48:8.1f} ms"
            f"  (sources peak {pk}, export wrote silence)"
        )

    total_drop = sum(l for _, l, _ in dropouts)
    print(
        f"[audio-audit] dropouts {len(dropouts)} ({total_drop/48:.1f} ms, "
        f"{total_drop/nsamples*100:.2f}% of timeline); faithful {len(faithful)}; "
        f"unverified {len(unverified)}"
    )
    if dropouts:
        print(f"[audio-audit] FAIL: {len(dropouts)} dropout(s) where the sources have audio")
        return 1
    print("[audio-audit] ok: every silence run is one the sources contain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
