# TODO

Open work only. Completed work is not tracked here — it is in the git history,
which is the durable record of what happened and why. This file was 9,345 lines
of mixed done/open notes; it was rebuilt from the 37 unchecked items in it after
triaging each against the current tree. Items that turned out to be done, done
in practice, or notes about a probe that no longer runs like that were dropped
rather than carried forward.

`IDEAs.md` is the speculative bank. Something moves here from there when it is
actually picked up, with a concrete design.

---

## 1. The timeline has two renderers (highest impact)

**Reproduced on a real project: a 30px horizontal skew on all 6 tracks.**

`build_page` (vyper.odin) lays the timeline out once and bakes the tiles and
their per-track scissor commands into a Clay command array. The GPU overlay
passes (ruler, render range, markers, keyframes, ghosts) instead recompute x
live as `lane.x + (frame - view.start) * zoom`.

A zoom click fires from the click table inside `interaction_post_build`, which
runs **after** `build_page`. So that frame bakes Clay at the old zoom, the
handler mutates the view, and the overlay draws at the new zoom against a lane
box from the stale stream. `VYPER_ZOOM_SKEW_PROBE` measures it against
`~/hello.vyproj`:

```
[skew-probe] track 0: clay drew tile at 244.0, overlay at 274.0 (skew -30.0)
...
[skew-probe] FAIL: 6 track(s) skewed between the baked Clay stream and the live GPU overlay
```

- [ ] **Option A: one geometry table.** The overlay passes read the baked
      command array instead of `timeline_view` live, so the frame has exactly one
      source of truth. Requires an explicit "freeze the view state at
      `build_page` time" step, because `interaction_post_build` mutating the view
      after the bake *is* the bug.
- [ ] `SDL_SetGPUScissor_REAL` overshoot follows from the same frame. Do not
      diagnose it independently until Option A lands — it will likely go with it.
- [ ] Re-run `VYPER_ZOOM_SKEW_PROBE` and make it a gate target, so this cannot
      regress silently. It currently needs a hand-set env var.

## 2. Debug builds write a trace file on every launch

`diag_path` (diag.odin) falls back to `<temp>/vyper/spall.json` when `VYPER_SPALL`
is unset, in debug builds only. A published `vyper-debug.exe` therefore opens a
spall capture and writes a trace every time it starts. The three continuous
traces (`VYPER_TRACE` / `VYPER_PLAY_TRACE` / `VYPER_REPRO_TRACE`) are likewise
on by default in debug.

The probes themselves are fine — every probe runner is env-gated, so a debug
launch with no env vars set runs the normal app. It is the tracing that litters.

- [ ] Default the tracing OFF in debug. Profiling should be something you turn
      on (`VYPER_SPALL=<path>`), not something a debug build does behind your
      back.
- [ ] Decide the CI artifact question below with this settled, since shipping a
      debug binary is only reasonable if a debug launch is inert.

## 3. CI ships a build one compiler behind the gates

`.github/workflows/windows.yml` pins `ODIN_VERSION: dev-2026-09`. `.mise.toml`
and the local toolchain are `dev-2026-10`.

This is the drift the workflow's own comment warns about: *"a compiler bump
changes codegen, which is exactly what a build gate is supposed to catch."*

- [ ] Bump CI to `dev-2026-10`, or make CI read the version from `.mise.toml` so
      it cannot drift again. The second is the fix; the first is the patch.

## 4. Windows crash-log fix is unverified locally

`crash_windows.odin` is `#+build windows` and this host has no Windows SDK, so a
Windows-target `odin check` was impossible. The Win32 signatures were read from
the Odin core and the path algorithm was validated standalone against stubbed
calls, but **the Windows compile itself is not machine-verified**.

CI compiles it on every push (the file is `#+build windows`, not debug-gated,
and the crash handler is `when ODIN_OS == .Windows` only), so the first Windows
CI run is the real check.

- [ ] Confirm the next green Windows run, and that `vyper_crash.log` appears
      **next to the exe** rather than in the working directory.

## 5. Windows import segfault — unreproduced, needs a Windows host

Reported by a user; never reproduced on Linux. Still the highest-severity
unknown here.

The leading candidate remains `portal_windows.odin`'s fixed
`[1024]byte` path buffers: the `copy` result `n` is then used as `buf[n] = 0`, so
a picked UTF-8 path at or over the buffer length writes one past the end.
Unconfirmed as the actual crash.

- [ ] Get `vyper_crash.log` (exception code + fault address) and the `[win-ff]`
      DLL-version line from the reporter. Both are now written somewhere findable,
      which is what makes this actionable at all.

## 6. Export: keyed compositor does avoidable work

The decoder is fed pixels nobody will see. Probed numbers: **~3.5s → ~1.1s at
720p, ~7.8s → ~2.4s at 1080p** for the simplest fix alone.

- [ ] **S2.** Clip keyed `sws` work to the current canvas intersection. Map the
      visible destination rect back to the stage source rect, clamp rounding at
      stage bounds, blit only the visible result. Lowest-risk first step; the
      probe above measured this shape.
- [ ] **S3.** One visibility envelope per keyed clip at render start: the union
      of on-canvas source regions over the clip's sampled poses, including crop
      insets. Configure decoder crop/stage once from it; never recompute
      allocations or decoder geometry per frame. Fall back to the full stage when
      not safely bounded.
- [ ] **S4.** Size keyed decode stages from the envelope rather than the maximum
      key scale. Size double buffers and `kres_scratch` from actual maximum
      destination dimensions. Preserve source aspect/crop semantics.
- [ ] **S5.** A scale track with no actual value variation is fixed scale: route it
      through the static visibility-crop path. Not for genuinely moving clips.
- [ ] **S6.** Only after S2–S5: reuse or cache `SwsContext`. Context creation
      measured ~0.2–0.5 ms/frame, so it is secondary to eliminating wasted pixels.
- [ ] **ACCEPT.** 720p and 1080p scale `1 -> 3` exports within 2x of their
      no-key baselines; no off-canvas full-box resampling; no per-frame
      allocations; frame count/duration and reference pixels unchanged.

## 7. Playback: two structural gaps, both deliberate

- [ ] **Re-investigate edit-time provision latency before picking this up.** The
      old notes here are no longer a description of the code: they said
      `audio_provision` reopens every decoder synchronously, at a quoted "hundreds
      of ms once several sources are open". That path now runs a **three-slot
      scheme** (`audio_geom_acquire` held across the whole provision, per-source
      `.Open` actions via `audio_anchor_sources`) and the quoted comment is gone
      from the tree. The idea that survived — a **generation counter**, so a
      provision for an edit that has already been superseded can be dropped instead
      of applied — is still sound, but the cost it was justified against has to be
      **measured again** before anyone builds it. Do not implement from the old
      description.
- [ ] **ACCEPT.** 2x AV1 1080p60 plays smooth, pitch preserved, full-res, cores
      free; mpv does no better. No `ffmpeg`/`ffprobe` strings in the binary.

      *(The companion "render preroll" item is gone: `AUDIO_SEEK_PREROLL_SEC` is
      0.5 and is applied in `decode_from_content`, the path both sinks share, so
      its stated symptom — preroll 0 for export — is already fixed. If the
      sample-domain counter half is still wanted, it needs its own description.)*

## 8. Multi-select clip actions have real gaps

`Active 50` shipped the common path; these parts are still single-clip.

- [ ] **PACKED section tracks are not handled.** The seeding pass does not cover
      transform/crop groups, so keying a group under a multi-selection is
      wrong or partial.
- [ ] **Trim severing.** `kf_trim_head`/`kf_trim_tail` has the same severing shape
      at a head/tail boundary as the cases already fixed.
- [ ] **`delete_clip_at`** (the click-through delete path) still branches on
      single-clip state.
- [ ] **`begin_clip_rename` (`Begin_Rename`)** is still anchor-only, deliberately.

## 9. Audio: two open items

- [ ] **Reverse playback is muted.** `playback.dir == -1` still mutes audio.
- [ ] **S4c — latency as a declared per-node quantity.** S4b found the divergence
      was never a latency to compensate but an ask that did not mean what it said,
      and fixed it at the source in `decode_from_content`. What remains is `swr`
      delay and `atempo` lookahead, **neither measured**. Measure before
      declaring: a declaration for an unmeasured delay is a guess with a type
      on it.
- [ ] **S6 — incremental/chunked export. Deferred 2026-10-02, not started.**
      Chunk cache keyed by `(document generation, frame range, source policy)`.
      The S1–S4 determinism it depends on has landed, so it is unblocked — but
      it needs a **document generation counter that does not exist yet**, and
      every mutator that can change a frame's output must bump it. A cache key
      that misses a mutation returns stale video.

## 10. `flake.nix` is unverified

Nix is not installed on this host, so its two `cp` steps have never run.

- [ ] Verify the flake builds, or say plainly that it is unsupported.

---

## Manual verification outstanding

These are shipped behaviours that only a human in the editor can sign off. They
are listed once here instead of as per-section ACCEPT boxes, because they are
the same category of thing and tracking them per-feature only made them harder
to see.

- [ ] Scrubbing produces audible audio (the device drains at 1x like any other
      path; never confirmed by ear).
- [ ] Black flashing between short stills — gone in the editor on
      `~/spooky.vyproj`?
- [ ] Fast scrubbing through stills — the recorded scrub (window 1908x1028)
      could not be replayed here.
- [ ] Multi-select clip actions exercised by hand rather than only by probe.
- [ ] `:save` / `:open` round-trip, bad-path notices, bare `:save` naming.
- [ ] Track context menu: Duplicate/Delete only, Add Track still reachable, rows
      visibly shorter, >5 tracks fitted without scrolling.
- [ ] In-app finder, if it is being kept: navigate, symlinks, fuzzy filter,
      import-to-bin. The finder is currently **bypassed** in favour of the OS
      picker (`FINDER_USE_OS_PICKER`), but intact and still covered by its probes.
- [ ] **The OS file picker blocks the main thread** while open, which the
      in-app finder did not. New behaviour; confirm it is acceptable.

## Known pre-existing gate failures

Both verified against an older base, so neither is a regression from current
work. They are not gates you can trust to be green yet.

- `image_decode_probe` — fails to decode every synthesized still. Verified
  failing on base `906e44c`.
- `parity_valgrind` — exceeds its 300s timeout; base and current both run ~15½
  minutes.