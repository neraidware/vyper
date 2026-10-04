// ---------------------------------------------------------------------------
// Project file (.vyproj): save/load the whole session as CBOR.
//
// `:save <path>` writes a snapshot of the project metadata (name, resolution,
// frame rate, render range, resolution lock) AND the editing session: the media
// bin, the subtitle cache, and the timeline (tracks, clips, markers, keyframe
// tracks, track order, playhead). `:open <path.vyproj>` reads it back and makes
// it the live session, replacing whatever was open. Bare `:save` opens the
// in-app file finder in Save mode, which suggests `<project name>.vyproj` as
// the field's placeholder and writes the name typed there in the browsed
// directory; bare `:open` pops the same finder in Open mode. The finder is the
// picker for both verbs, so both must agree on what a project file is
// (PROJECT_FILE_EXTENSION).
//
// Format: core:encoding/cbor, reflection-marshaled over Project_File. No
// version/escalation machinery: single-user tool, the file layout only ever has
// one reader (this build), so a changed struct just recodes.
//
// Loading is a real session SWITCH, so the first thing project_file_open does
// after a successful decode is tear the old session down (session_teardown) and
// rebuild from the DTO (session_rebuild). Every allocation the live session
// owns is freed there: timeline (free_timeline), undo (undo_free_all), the srt
// cache (srt_cache_free_all), the media bin's path/metadata copies
// (media_bin_free), and the bin's GPU thumbnails (release_media_asset_textures
// when a renderer exists). Thumbnails are re-decoded on load; src_hw is
// re-probed lazily. Undo history is not serialized -- the loaded session
// becomes undo's baseline (undo_init).
//
// clip.path is NOT serialized: for a file-backed clip it is the asset's path
// (import_media_to_bin stores asset.path), so the load re-derives it via
// find_asset(asset_id). Generator clips (Text/Subtitles) have no path. Asset
// paths in the file are plain strings (cstring does not serialize) and become
// the bin's own session cstrings on load.
// ---------------------------------------------------------------------------
package main

import "core:c"
import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:strings"

// Saved_Asset is one media-bin entry as stored in the file. It carries the
// asset's identity (id), the source path, the probe results that drive the bin
// row and the drop defaults, and the subtitle cache index. The lazily-probed
// hardware-decoder flag (src_hw/src_hw_known) and the thumbnails are NOT
// stored -- they are re-derived (thumbnails re-decoded, src_hw re-probed) after
// load.
Saved_Asset :: struct {
	id:            u64,
	path:          string,
	kind:          Media_Kind,
	metadata:      string,
	frame_count:   i64,
	dur_us:        i64,
	src_w:         c.int,
	src_h:         c.int,
	audio_streams: c.int,
	audio_frames:  i64,
	audio_rate:    f64,
	is_image:      bool,
	srt_id:        int,
}

// Saved_Marker is a marker as stored in the file. It exists only because the
// live Clip_Marker.label became a session-pool HANDLE rather than a string
// (TODO.md Active 19), which makes the live type no longer cbor-safe -- the
// decoder would read a CBOR string into two i32s. Field names and types match
// what Clip_Marker used to encode, so the on-disk format is unchanged; only the
// in-memory DTO type is explicit now.
Saved_Marker :: struct {
	source_frame: i64,
	label:        string,
}

// Saved_Clip is one timeline clip as stored in the file: every authored field
// (identity, timing, transform, crop, gain, stream) plus its markers and
// keyframe tracks. Markers use the Saved_Marker DTO above. Kf_Track is still
// reused directly (its name is a plain string until step 2 moves it into the
// pool, which must introduce its own DTO the same way). path is NOT stored --
// see the header note.
Saved_Clip :: struct {
	clip_id:              u64,
	asset_id:             u64,
	link_id:              u64,
	name:                 string,
	kind:                 Media_Kind,
	is_still:             bool,
	generator:            Generator_Kind,
	srt_id:               int,
	stream_index:         c.int,
	gain:                 f32,
	source_start_frame:   i64,
	audio_src_rate:       f64,
	source_length_frames: i64,
	timeline_start_frame: i64,
	source_w:             c.int,
	source_h:             c.int,
	transform_x:          f32,
	transform_y:          f32,
	scale:                f32,
	crop_l:               f32,
	crop_r:               f32,
	crop_t:               f32,
	crop_b:               f32,
	// opacity plus an explicit presence flag. A project written before opacity
	// existed has no such field, and a missing f32 decodes to 0 -- which would
	// load every old clip fully transparent. The flag distinguishes "absent"
	// (default 1) from a legitimately 0% clip. Odin's json decoder rejects
	// pointer fields, so presence cannot be inferred from a nil ^f32.
	opacity:              f32,
	has_opacity:          bool,
	markers:              [dynamic]Saved_Marker,
	keyframe_tracks:      [dynamic]Saved_Kf_Track,
}

// Saved_Kf_Track is a keyframe track as stored in the file, for the same reason
// Saved_Marker exists: the live Kf_Track.name is a session-pool HANDLE
// (TODO.md Active 19), so reusing the live type would write two i32s where the
// file stores a name. Its `keys` field reuses the live [dynamic]Keyframe, which
// IS still cbor-safe (scalars plus a fixed-array union variant) -- that stops
// being true when the keys move into a session store.
Saved_Kf_Track :: struct {
	name: string,
	keys: [dynamic]Keyframe,
}

// Saved_Track is one storage track: its name and its clips in order.
Saved_Track :: struct {
	name:  string,
	clips: [dynamic]Saved_Clip,
}

// Project_File is the whole serialized project: the Project identity fields
// plus the session. assets/srt_sources/tracks are the containers the save side
// allocates; their elements alias the live session (so a save copies almost no
// bytes -- the strings and inner arrays are the live ones) and the containers
// are freed after the encode.
Project_File :: struct {
	// Project identity.
	name:              string,
	width:             c.int,
	height:            c.int,
	frame_rate:        f64,
	start_frame:       i64,
	end_frame:         i64,
	resolution_locked: bool,
	// Session.
	next_asset_id:       u64,
	assets:              [dynamic]Saved_Asset,
	srt_sources:         [dynamic]Srt_Source,
	tracks:              [dynamic]Saved_Track,
	track_order:         [dynamic]int,
	playhead_frame:      i64,
	timeline_frame_rate: f64,
}

// project_name_owned tracks whether project.name is a session-heap clone
// (loaded from a file) rather than the default literal "Untitled Project".
// The literal must never be deleted; a replaced loaded name must be.
project_name_owned: bool

// project_set_name replaces project.name with a clone of `name`; frees any
// previous loaded name so repeated opens don't leak.
project_set_name :: proc(name: string) {
	if project_name_owned {
		delete(project.name)
	}
	project.name = strings.clone(name)
	project_name_owned = true
}

// ---------------------------------------------------------------------------
// Save side
// ---------------------------------------------------------------------------

// project_to_file copies the live Project + session into its serializable shape.
// The three container arrays (assets, srt_sources, tracks) are freshly
// allocated; their ELEMENTS reference the live session (paths as string views,
// metadata/name as-is, markers/keyframe_tracks/srt cues as-is), so the encode
// reads live memory without copying it. project_file_free_containers releases
// the containers after the encode -- and nothing else, because the aliased
// inner memory belongs to the live session.
project_to_file :: proc() -> Project_File {
	pf := Project_File {
		name              = project.name,
		width             = project.width,
		height            = project.height,
		frame_rate        = project.frame_rate,
		start_frame       = project.start_frame,
		end_frame         = project.end_frame,
		resolution_locked = project.resolution_locked,
		next_asset_id     = media_bin.next_id,
		playhead_frame    = timeline.playhead_frame,
		timeline_frame_rate = timeline.frame_rate,
	}

	pf.assets = make([dynamic]Saved_Asset, 0, len(media_bin.assets))
	for a in media_bin.assets {
		append(&pf.assets, Saved_Asset {
			id            = a.id,
			path          = string(a.path), // string view over the cstring
			kind          = a.kind,
			metadata      = a.metadata,
			frame_count   = a.frame_count,
			dur_us        = a.dur_us,
			src_w         = a.src_w,
			src_h         = a.src_h,
			audio_streams = a.audio_streams,
			audio_frames  = a.audio_frames,
			audio_rate    = a.audio_rate,
			is_image      = a.is_image,
			srt_id        = a.srt_id,
		})
	}

	// Shallow copy of the srt cache: each Srt_Source element aliases the live
	// path string and cue array; only the outer array is ours.
	pf.srt_sources = make([dynamic]Srt_Source, len(srt_cache))
	copy(pf.srt_sources[:], srt_cache[:])

	pf.tracks = make([dynamic]Saved_Track, 0, len(timeline.tracks))
	for t in timeline.tracks {
		st := Saved_Track {
			name  = t.name, // string view
			clips = make([dynamic]Saved_Clip, 0, len(t.clips)),
		}
		for &c in t.clips {
			append(&st.clips, Saved_Clip {
				clip_id              = c.clip_id,
				asset_id             = c.asset_id,
				link_id              = c.link_id,
				name                 = clip_name(&c),
				kind                 = c.kind,
				is_still             = c.is_still,
				generator            = c.generator,
				srt_id               = c.srt_id,
				stream_index         = c.stream_index,
				gain                 = c.gain,
				source_start_frame   = c.source_start_frame,
				audio_src_rate       = c.audio_src_rate,
				source_length_frames = c.source_length_frames,
				timeline_start_frame = c.timeline_start_frame,
				source_w             = c.source_w,
				source_h             = c.source_h,
				transform_x          = c.transform_x,
				transform_y          = c.transform_y,
				scale                = c.scale,
				crop_l               = c.crop_l,
				crop_r               = c.crop_r,
				crop_t               = c.crop_t,
				crop_b               = c.crop_b,
				opacity              = c.opacity,
				has_opacity          = true,
				markers              = saved_markers(&c),
				keyframe_tracks      = saved_kf_tracks(&c),
			})
		}
		append(&pf.tracks, st)
	}

	pf.track_order = make([dynamic]int, len(timeline.track_order))
	copy(pf.track_order[:], timeline.track_order[:])
	return pf
}

// project_file_free_containers releases the container arrays the save side
// allocated, each track's clips array, and each clip's marker/keyframe DTO
// arrays. String fields inside DTOs are borrowed pool views; scalar fields and
// inline key payloads are values.
//
// The marker arrays are the exception: saved_markers BUILDS them for the encode
// (the live type is a pool handle, not a cbor-safe struct -- see Saved_Marker),
// so they are this save's to free. Their labels are borrowed pool views and own
// nothing, so dropping the array is the whole free.
project_file_free_containers :: proc(pf: ^Project_File) {
	for &st in pf.tracks {
		for &sc in st.clips {
			for &kt in sc.keyframe_tracks {
				// The DTO's keys array is THIS save's (built by
				// saved_kf_tracks); its name is a borrowed pool view.
				delete(kt.keys)
			}
			delete(sc.keyframe_tracks)
			delete(sc.markers)
		}
		delete(st.clips)
	}
	delete(pf.tracks)
	delete(pf.assets)
	delete(pf.srt_sources)
	delete(pf.track_order)
}

// project_file_save writes the current project + session snapshot to `path` as
// CBOR. Returns a notice text on failure ("" = success).
project_file_save :: proc(path: string) -> string {
	pf := project_to_file()
	defer project_file_free_containers(&pf)
	data, err := cbor.marshal(pf, cbor.ENCODE_FULLY_DETERMINISTIC)
	if err != nil {
		return fmt.aprintf("failed to encode project: %v", err)
	}
	defer delete(data)
	if werr := os.write_entire_file(path, data); werr != nil {
		return fmt.aprintf("failed to write '%s': %v", path, werr)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Load side
// ---------------------------------------------------------------------------

// session_teardown frees the whole live session so a load can replace it: the
// timeline, the undo history, the srt cache, the media bin's heap memory, and
// (when a renderer exists) the bin's GPU thumbnails. Document-keyed selection
// and the keyframe selection are dropped because they are index/id-keyed to the
// tree that was just freed. The GPU release is guarded because a headless
// session (VYPER_UI_PROBE runs before the GPU exists) has no renderer and no
// textures.
session_teardown :: proc() {
	if gpu_renderer != nil {
		release_media_asset_textures(gpu_renderer.device)
	}
	free_timeline(&timeline)
	undo_free_all()
	// Every Clip, marker and keyframe-track range dies with these session pools.
	// Nothing above survives: live timeline and undo snapshots are released first.
	// Pool resets are blind rewinds for the reason recorded in TODO.md Active 19
	// S0 -- no Clip, snapshot or timeline outlives teardown, so there is nothing
	// to invalidate beyond the bounds assert on the read side.
	session_str_reset()
	session_kf_reset()
	session_trk_reset()
	session_marker_reset()
	srt_cache_free_all()
	media_bin_free()
	clear(&selection.extra_set)
	selection.asset_id = 0
	selection.track = -1
	selection.index = -1
	kf_selection_free()
}

// session_rebuild makes decoded DTO values live: strings/marker/key rows enter
// session pools, while timeline containers use session heap. The DTO itself
// lives on frame temp and dies at the next free_all. Mirrors import reset, then
// resets undo so loaded session is new baseline.
session_rebuild :: proc(pf: ^Project_File) {
	// Project identity.
	project_set_name(pf.name)
	if pf.width > 0 && pf.height > 0 {
		project.width = pf.width
		project.height = pf.height
	}
	project.frame_rate = pf.frame_rate
	project.start_frame = pf.start_frame
	project.end_frame = pf.end_frame
	project.resolution_locked = pf.resolution_locked

	// Media bin. Restore each id verbatim and re-decode its thumbnail; src_hw
	// is left un-probed (the lazy prober fills it on first use).
	highest_id := u64(0)
	for sa in pf.assets {
		append(
			&media_bin.assets,
			Media_Asset {
				id            = sa.id,
				path          = strings.clone_to_cstring(sa.path),
				kind          = sa.kind,
				metadata      = strings.clone(sa.metadata),
				frame_count   = sa.frame_count,
				dur_us        = sa.dur_us,
				src_w         = sa.src_w,
				src_h         = sa.src_h,
				audio_streams = sa.audio_streams,
				audio_frames  = sa.audio_frames,
				audio_rate    = sa.audio_rate,
				is_image      = sa.is_image,
				srt_id        = sa.srt_id,
				thumb_tex_dirty = true,
			},
		)
		highest_id = max(highest_id, sa.id)
		decode_asset_thumbnail(&media_bin.assets[len(media_bin.assets) - 1])
	}
	// The next import must not collide with a restored id: honor the saved
	// allocator, but never hand out an id an asset already holds.
	media_bin.next_id = max(pf.next_asset_id, highest_id + 1)

	// Subtitle cache, rebuilt in the saved order so the srt_id indices stored
	// in restored assets and clips point at the same sources they did before.
	for ss in pf.srt_sources {
		src := Srt_Source {
			path = strings.clone(ss.path),
			cues = make([dynamic]Srt_Cue, 0, len(ss.cues)),
		}
		for cue in ss.cues {
			append(&src.cues, Srt_Cue {
				start_ms = cue.start_ms,
				end_ms   = cue.end_ms,
				text     = strings.clone(cue.text),
			})
		}
		append(&srt_cache, src)
	}

	// Timeline. clip.path is re-derived (file-backed -> the asset's owned path,
	// generator -> nil); every owned string/array is a fresh session copy.
	for st in pf.tracks {
		tr := Track {
			name  = strings.clone(st.name),
			clips = make([dynamic]Clip, 0, len(st.clips)),
		}
		for sc in st.clips {
			c := Clip {
				clip_id              = sc.clip_id,
				asset_id             = sc.asset_id,
				link_id              = sc.link_id,
				name                 = session_str_intern(sc.name),
				kind                 = sc.kind,
				is_still             = sc.is_still,
				generator            = sc.generator,
				srt_id               = sc.srt_id,
				stream_index         = sc.stream_index,
				gain                 = sc.gain,
				source_start_frame   = sc.source_start_frame,
				audio_src_rate       = sc.audio_src_rate,
				source_length_frames = sc.source_length_frames,
				timeline_start_frame = sc.timeline_start_frame,
				source_w             = sc.source_w,
				source_h             = sc.source_h,
				transform_x          = sc.transform_x,
				transform_y          = sc.transform_y,
				scale                = sc.scale,
				crop_l               = sc.crop_l,
				crop_r               = sc.crop_r,
				crop_t               = sc.crop_t,
				crop_b               = sc.crop_b,
				opacity              = 1.0,
			}
			// Absent (pre-opacity project) loads fully opaque; a stored 0% is real.
			if sc.has_opacity {
				c.opacity = sc.opacity
			}
			if sc.generator == .None {
				if a := find_asset(sc.asset_id); a != nil {
					c.path = a.path
				}
			}
			// Marker labels and rows enter session pools; DTO strings stay plain
			// CBOR values and remain format-compatible.
			if len(sc.markers) > 0 {
				c.markers = Clip_Markers_Range{}
				for sm in sc.markers {
					session_marker_push(&c.markers, Clip_Marker {
						source_frame = sm.source_frame,
						label        = session_str_intern(sm.label),
					})
				}
			}
			// Rebuild session ranges from the plain-string/key-array file DTO.
			if len(sc.keyframe_tracks) > 0 {
				c.keyframe_tracks = Kf_Track_Range{}
				for kt in sc.keyframe_tracks {
					r := session_kf_make(kt.keys[:])
					session_trk_push(&c.keyframe_tracks, Kf_Track{name=session_str_intern(kt.name), keys=r})
				}
			}
			append(&tr.clips, c)
		}
		append(&timeline.tracks, tr)
	}
	timeline.track_order = make([dynamic]int, len(pf.track_order))
	copy(timeline.track_order[:], pf.track_order[:])
	timeline.playhead_frame = pf.playhead_frame
	timeline.frame_rate = pf.timeline_frame_rate
	pf_pin_audio_src_rates()

	// Post-load reset: a full session replace invalidates every decoder, the
	// preview cache, and playback state. Mirrors the import post-edit block.
	playhead.frame = timeline.playhead_frame
	playhead.playing = false
	playback.accumulator = 0
	preview.playing = false
	preview.last_decoded = -1
	preview.last_requested = -1
	async_dec_reset()
	if warm.valid {
		clip_decoder_reset(&warm.decoder)
		warm.valid = false
		warm.clip_id = 0
	}
	audio_reset_for_load()
	invalidate_preview_slots()
	audio_note_edit()

	// The loaded session is undo's new baseline.
	undo_init()
	// A loaded project can carry more tracks than fit; fit the track list so the
	// first ones are visible without scrolling.
	fit_timeline_to_tracks()
}

// project_file_open reads `path` as CBOR and makes it the live session,
// replacing the current one. The decoded DTO lives on the frame temp arena
// (allocator := context.temp_allocator) and is reclaimed at the next free_all;
// session_rebuild copies everything it needs into the session heap, so the DTO
// can be transient. Returns a notice text on failure ("" = success); a failed
// read/decode leaves the live session untouched.
// pf_pin_audio_src_rates pins the source-frame space of every audio clip that
// has none (a project saved before Clip.audio_src_rate existed).
//
// Without this, opening such a project and then changing the rate re-points its
// audio clips at a different part of their file -- the defect this pin exists to
// remove. The pin has to be taken HERE, at load, while the project's own rate is
// still the one the frame numbers were written against; afterwards the rate is
// mutable and the original value is unrecoverable.
//
// Preference order: the asset's own import rate (exact -- it is the rate
// audio_frames was measured with), else the project's effective rate at load.
// A project that was last saved while its rate already disagreed with the rate
// it was authored at cannot be recovered -- nothing in the file records the
// authoring rate -- so the effective rate is the best available reading.
pf_pin_audio_src_rates :: proc() {
	rate := project_fps()
	for ti in 0 ..< len(timeline.tracks) {
		for ci in 0 ..< len(timeline.tracks[ti].clips) {
			c := &timeline.tracks[ti].clips[ci]
			if c.kind != .Audio || c.audio_src_rate > 0 {
				continue
			}
			pinned := rate
			if as := find_asset(c.asset_id); as != nil && as.audio_rate > 0 {
				pinned = as.audio_rate
			}
			c.audio_src_rate = pinned
		}
	}
}

project_file_open :: proc(path: string) -> string {
	bytes, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return fmt.aprintf("failed to read '%s': %v", path, rerr)
	}

	pf: Project_File
	uerr := cbor.unmarshal_from_bytes(bytes, &pf, cbor.Decoder_Flags{}, context.temp_allocator)
	if uerr != nil {
		return fmt.aprintf("'%s' is not a valid project file: %v", path, uerr)
	}

	session_teardown()
	session_rebuild(&pf)
	return ""
}

// PROJECT_FILE_EXTENSION marks a file as a project: `:open` and the finder
// dispatch on it, so it is the single source of truth for both the routing test
// and the name Save mode suggests.
PROJECT_FILE_EXTENSION :: ".vyproj"

// project_path_is_project reports whether a path names a project file (by its
// .vyproj extension). The finder and :open route non-project paths to media;
// this is the dispatch test.
project_path_is_project :: proc(path: string) -> bool {
	return strings.has_suffix(path, PROJECT_FILE_EXTENSION)
}

// saved_markers renders a clip's markers as the file DTO. The labels are
// borrowed views of the session pool, valid for the whole save: the pool is not
// touched while the file is being built, and the DTO is consumed immediately
// after. Returning an empty (non-nil) array for a clip with no markers keeps the
// encoder from emitting a null where the old aliased array would have emitted a
// list.
saved_markers :: proc(c: ^Clip) -> [dynamic]Saved_Marker {
	out := make([dynamic]Saved_Marker, c.markers.n)
	for i in 0..<c.markers.n {
		m := session_marker_at(c.markers, i)
		out[i] = Saved_Marker {
			source_frame = m.source_frame,
			label        = marker_label(&m),
		}
	}
	return out
}

// saved_kf_tracks renders a clip's keyframe tracks as the file DTO. The lane
// names are borrowed views of the session pool, valid for the whole save; the
// key arrays are copies, because the live ones are freed by kf_free_tracks and
// the encode must not depend on the session staying put. The arrays are freed by
// project_file_free_containers.
saved_kf_tracks :: proc(c: ^Clip) -> [dynamic]Saved_Kf_Track {
	out := make([dynamic]Saved_Kf_Track, c.keyframe_tracks.n)
	for i in 0..<c.keyframe_tracks.n {
		t := session_trk_view(c.keyframe_tracks, i)
		vv := session_kf_view(t.keys)
		keys := make([dynamic]Keyframe, len(vv))
		for j in 0..<len(vv) { keys[j] = vv[j] }
		out[i] = Saved_Kf_Track {name = kf_track_name(t), keys = keys}
	}
	return out
}
