package vyper

import "core:crypto/sha2"
import "core:sync"
import "core:time"

// Clip_Id_State is the process-wide clip-identity generator. `seed` is a
// monotonic counter, guaranteeing uniqueness even if two clips are minted
// within the same wall-clock nanosecond (fast import/split loops, or a
// low-resolution clock on some platforms). Kept as one named state object so
// the id space has a home; new_clip_id is the only reader/writer.
Clip_Id_State :: struct {
	seed: u64,
}

clip_id: Clip_Id_State

// new_clip_id mints a fresh, stable identity for one clip *instance* -- not
// its content. Two split halves of the same asset must NOT collide, and a
// clip dragged along the timeline must keep the SAME id even though its
// asset_id/timeline_start_frame/source_start_frame all stay identical to
// another clip's at different times. The seed counter alone already
// guarantees uniqueness; SHA-256 just gives a fixed-width, opaque id in the
// same shape as the existing asset_id: u64, rather than a bare incrementing
// counter leaking creation order.
//
// Call this exactly once per clip *instance*: on import, and for the NEW
// half produced by a split (the half that keeps its old struct/slot keeps
// its old id -- it's still logically the same clip, just shorter).
new_clip_id :: proc() -> u64 {
	seed := sync.atomic_add(&clip_id.seed, 1)
	now := u64(time.to_unix_nanoseconds(time.now()))

	buf: [16]u8
	for i in 0 ..< 8 {
		buf[i] = u8(seed >> uint(i * 8))
		buf[8 + i] = u8(now >> uint(i * 8))
	}

	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, buf[:])
	digest: [32]u8
	sha2.final(&ctx, digest[:])

	id: u64
	for i in 0 ..< 8 {
		id |= u64(digest[i]) << uint(i * 8)
	}
	return id
}
