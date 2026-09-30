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
	is_image:      bool,
	srt_id:        int,
}

// Saved_Clip is one timeline clip as stored in the file: every authored field
// (identity, timing, transform, crop, gain, stream) plus its markers and
// keyframe tracks. The live Clip_Marker / Kf_Track types are already cbor-safe
// (scalar + a packed-union value) so they are reused directly. path is NOT
// stored -- see the header note.
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
	markers:              [dynamic]Clip_Marker,
	keyframe_tracks:      [dynamic]Kf_Track,
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
		for c in t.clips {
			append(&st.clips, Saved_Clip {
				clip_id              = c.clip_id,
				asset_id             = c.asset_id,
				link_id              = c.link_id,
				name                 = c.name,
				kind                 = c.kind,
				is_still             = c.is_still,
				generator            = c.generator,
				srt_id               = c.srt_id,
				stream_index         = c.stream_index,
				gain                 = c.gain,
				source_start_frame   = c.source_start_frame,
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
				markers              = c.markers,         // live array, aliased
				keyframe_tracks      = c.keyframe_tracks, // live array, aliased
			})
		}
		append(&pf.tracks, st)
	}

	pf.track_order = make([dynamic]int, len(timeline.track_order))
	copy(pf.track_order[:], timeline.track_order[:])
	return pf
}

// project_file_free_containers releases the three container arrays the save
// side allocated, and each track's clips array. The ELEMENTS alias live session
// memory (strings, marker/keyframe/srt arrays) and are NOT touched -- freeing
// them would corrupt the session being saved.
project_file_free_containers :: proc(pf: ^Project_File) {
	for &st in pf.tracks {
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
	srt_cache_free_all()
	media_bin_free()
	clear(&selection.extra_set)
	selection.asset_id = 0
	selection.track = -1
	selection.index = -1
	kf_sel = {}
}

// session_rebuild makes the decoded DTO the live session. Every string and
// dynamic array it installs is a fresh session-heap copy (the DTO itself lives
// on the frame temp arena and dies at the next free_all), so nothing here
// references the DTO after it returns. Mirrors the import post-edit reset, then
// resets undo so the loaded session is the new baseline.
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
				name                 = strings.clone(sc.name),
				kind                 = sc.kind,
				is_still             = sc.is_still,
				generator            = sc.generator,
				srt_id               = sc.srt_id,
				stream_index         = sc.stream_index,
				gain                 = sc.gain,
				source_start_frame   = sc.source_start_frame,
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
			// Marker labels are cloned (the DTO's die with the frame arena) and,
			// like live marker labels, are never freed by free_timeline -- they
			// are shared-by-design across split/duplicate.
			if len(sc.markers) > 0 {
				c.markers = make([dynamic]Clip_Marker, len(sc.markers))
				idx := 0
				for m in sc.markers {
					c.markers[idx] = Clip_Marker {
						source_frame = m.source_frame,
						label        = strings.clone(m.label),
					}
					idx += 1
				}
			}
			// Deep-copy the keyframe tracks (names + keys) off the DTO.
			kf_clone_mut(&c, Clip{keyframe_tracks = sc.keyframe_tracks})
			append(&tr.clips, c)
		}
		append(&timeline.tracks, tr)
	}
	timeline.track_order = make([dynamic]int, len(pf.track_order))
	copy(timeline.track_order[:], pf.track_order[:])
	timeline.playhead_frame = pf.playhead_frame
	timeline.frame_rate = pf.timeline_frame_rate

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
