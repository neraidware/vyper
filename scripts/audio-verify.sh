#!/usr/bin/env bash
# Verify an EXPORTED project's audio against its sources, sample-accurately.
#
#   scripts/audio-verify.sh <project.vyproj> [out.mp4]
#
# Not a gate: it needs a real project and the media it references, so it cannot
# run anywhere but on a machine that has them. It exists because the synthetic
# fixtures that the gates use cannot answer the questions that actually matter
# about a real edit -- where the content LANDS, whether it is the right content,
# and whether the export is the length the frame grid says it should be. A hole
# counter alone cannot tell "correct audio with a gap" from "the wrong audio".
#
# What it reports, per audio clip region of the project:
#   lag       samples the export's audio is shifted against the source. 0 is the
#             only correct answer; anything else is the sample-offset class of bug
#             (a fifo labelled with a position derived a different way) and it is
#             invisible to every frame-domain counter in the engine.
#   corr      correlation of the export against N x source, N being the number of
#             audio tracks carrying the same clip. Below ~0.98 means wrong content.
#   rms       error against N x source. Large where the source itself clips,
#             because N copies of a full-scale signal clip.
# Plus the whole-file numbers: sample count against the frame grid, and
# mid-content digital-silence runs.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

PROJ=${1:?usage: scripts/audio-verify.sh <project.vyproj> [out.mp4]}
OUT=${2:-/tmp/audio-verify-$$.mp4}
[ -f "$PROJ" ] || { echo "no such project: $PROJ" >&2; exit 1; }

BIN=./target/vyper
[ -x "$BIN" ] || { echo "build first: scripts/gate.sh build" >&2; exit 1; }

echo "==> exporting $PROJ"
VYPER_PARITY_PROBE="$PROJ|$OUT" timeout 3600 "$BIN" 2>&1 | grep -E "export status" || true
[ -s "$OUT" ] || { echo "export produced nothing" >&2; exit 1; }

echo "==> comparing against sources"
python3 - "$PROJ" "$OUT" <<'PY'
import cbor2, subprocess, sys, wave, tempfile, os
import numpy as np

proj, mp4 = sys.argv[1], sys.argv[2]
p = cbor2.load(open(proj, 'rb'))
fps = p['timeline_frame_rate']
if not fps or fps <= 0:
    sys.exit("project has no frame rate")
spf = 48000 // int(fps)
tracks = [t for t in p['tracks'] if any(c.get('kind') == 1 for c in t['clips'])]
NT = max(1, len(tracks))
end = p['end_frame']

def decode(src, seconds, mono=True):
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tf:
        path = tf.name
    cmd = ['ffmpeg', '-v', 'error', '-y']
    if seconds: cmd += ['-t', str(seconds)]
    cmd += ['-i', src, '-map', '0:a:0', '-ac', '1' if mono else '2',
            '-ar', '48000', '-c:a', 'pcm_s16le', path]
    subprocess.run(cmd, check=True)
    w = wave.open(path, 'rb')
    n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
    raw = w.readframes(n)
    w.close()
    os.unlink(path)
    a = np.frombuffer(raw, dtype='<i2').astype(np.float32)
    return a.reshape(-1, ch)[:, 0]

def corr(a, b):
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    return float(np.dot(a, b) / (na * nb)) if na > 1e-6 and nb > 1e-6 else None

exp = decode(mp4, None)
grid = (end - p['start_frame']) * spf
print(f"export {len(exp)} samples ({len(exp)/48000:.4f}s); grid wants {grid} "
      f"({end - p['start_frame']} frames x {spf}); delta {len(exp) - grid:+d} samples "
      f"({(len(exp)-grid)/48.0:+.1f} ms)")

# Source window: far enough to cover every clip's source range the render can see.
need = max((c['source_start_frame'] + min(c['source_length_frames'],
           end - c['timeline_start_frame']) for t in tracks for c in t['clips']
           if c.get('kind') == 1), default=0)
# Every asset, not just the ones the bin classifies as audio: a video file's
# AUDIO track is a perfectly good source for an audio clip, and that is the
# common case here (the clips reference the screen recording, whose kind is Video).
srcs = {a['id']: a['path'] for a in p['assets'] if a.get('path')}
need_sec = need / int(fps) + 2

print(f"\n{'frame':>6} {'len':>5} {'lag':>5} {'corr':>8} {'rms':>7}  verdict")
decoded = {}
bad = checked = 0
for tr in tracks[:1]:
    for c in tr['clips']:
        if c.get('kind') != 1: continue
        t0, n, s0 = c['timeline_start_frame'], c['source_length_frames'], c['source_start_frame']
        e0, elen, s1 = t0 * spf, n * spf, int(s0 * spf)
        if e0 + elen > len(exp): continue
        path = srcs.get(c.get('asset_id'))
        if not path: continue
        if path not in decoded:
            decoded[path] = decode(path, need_sec)
        src = decoded[path]
        if s1 + elen > len(src):
            print(f"{t0:>6} {n:>5} {'-':>5} {'n/a':>8} {'-':>7}  SOURCE WINDOW TOO SHORT")
            continue
        # The declick ramps are supposed to make the output DIFFER from a naive
        # N x source inside AUDIO_DECLICK_SAMPLES of the clip's own edges, so
        # those bands are excluded from the correlation and checked separately
        # below. Including them measures the ramp instead of the content.
        band = min(256, elen // 4)
        lo, hi = band, elen - band
        if hi <= lo:
            lo, hi = 0, elen
        want = src[s1+lo:s1+hi] * NT
        got = exp[e0+lo:e0+hi]
        best = (0, corr(want, got))
        for lag in (-spf, -spf//2, 0, spf//2, spf):
            aa, bb = (want[:len(want)-lag], got[lag:]) if lag >= 0 else (want[-lag:], got[:len(got)+lag])
            if len(aa) < spf: continue
            v = corr(aa, bb)
            if v is not None and (best[1] is None or v > best[1]): best = (lag, v)
        lag, cv = best
        err = float(np.sqrt(np.mean((want - got) ** 2)))
        checked += 1
        # Declick: a contribution must ARRIVE from silence rather than at full
        # level, so the export's first samples of the clip have to be far below
        # what the source is doing there. Before the ramp this ratio is ~1.
        ref = float(np.max(np.abs(src[s1+lo:s1+hi]))) * NT
        if ref > 64.0:
            first = float(np.max(np.abs(exp[e0:e0+8])))
            if first / ref > 0.05:
                print(f"{t0:>6} {n:>5} {'-':>5} {'n/a':>8} {'-':>7}  "
                      f"NO DECLICK: starts at {first/ref*100:.0f}% of {ref:.0f}")
                bad += 1
        if cv is None:
            ok = err == 0
            cs, verdict = "n/a", ("both silent (exact)" if ok else "SILENT MISMATCH")
        else:
            ok = lag == 0 and cv > 0.98
            cs, verdict = f"{cv:8.4f}", ("ok" if ok else ("MISALIGNED" if lag else "LOW CORR"))
        if not ok: bad += 1
        print(f"{t0:>6} {n:>5} {lag:>5} {cs} {err:>7.0f}  {verdict}")

# A silence run is only a HOLE if the export should have had sound there. A
# recording with a quiet passage produces a silence run that is the content
# faithfully reproduced, and counting it as a defect is how a hole counter ends up
# reporting the same number forever and getting ignored. The expected signal is
# already built per clip above, so the mask is free.
audible = np.zeros(len(exp), dtype=bool)
for tr in tracks[:1]:
    for c in tr['clips']:
        if c.get('kind') != 1: continue
        t0, n, s0 = c['timeline_start_frame'], c['source_length_frames'], c['source_start_frame']
        e0, elen, s1 = t0 * spf, n * spf, int(s0 * spf)
        if e0 + elen > len(exp): continue
        path = srcs.get(c.get('asset_id'))
        if not path: continue
        src = decoded.get(path)
        if src is None or s1 + elen > len(src): continue
        audible[e0:e0 + elen] |= np.abs(src[s1:s1 + elen]) > 64.0

runs, i = [], 0
L = exp
while i < len(L):
    if L[i] == 0:
        j = i
        while j < len(L) and L[j] == 0: j += 1
        if (j - i) > 48000 * 0.004 and audible[i:j].any():
            runs.append((i / 48000, (j - i) / 48000))
        i = j
    else: i += 1
edges = sorted({c['timeline_start_frame'] / fps for t in tracks for c in t['clips'] if c.get('kind') == 1}
               | {c['timeline_start_frame'] / fps + c['source_length_frames'] / fps
                  for t in tracks for c in t['clips'] if c.get('kind') == 1})
mid = [(t, d) for t, d in runs if min(abs(t - e) for e in edges) >= 0.030]
print(f"\nmid-content digital-silence runs >4ms: {len(mid)} "
      f"({sum(d for _, d in mid)*1000:.0f} ms)   [boundary-adjacent: {len(runs)-len(mid)}]")
print(f"checked {checked} clip regions; {bad} not clean; {len(mid)} holes where sound was due")
sys.exit(1 if bad or mid else 0)
PY
rc=$?
rm -f "$OUT"
exit $rc
