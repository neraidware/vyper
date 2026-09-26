// ---------------------------------------------------------------------------
// Project file (.vyproj): save/load the project metadata as CBOR.
//
// The basics only: `:save <path>` writes a snapshot of the Project struct
// (name, resolution, frame rate, render range, resolution lock) and
// `:open <path.vyproj>` reads it back and applies it. The timeline, media bin,
// and undo history are deliberately NOT part of the file yet -- restoring a
// session is a later step of the project-management work stream.
//
// Format: core:encoding/cbor, reflection-marshaled over Project_File. No
// version/escalation machinery: single-user tool, the file layout only ever
// has one reader (this build), so a changed struct just recodes.
// ---------------------------------------------------------------------------
package main

import "core:c"
import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:strings"

// Project_File is the serialized project snapshot: every Project field that
// identifies the project or drives its canvas. Session state (timeline, bin,
// undo) is absent by design until the save/restore workstream reaches it.
Project_File :: struct {
	name:              string,
	width:             c.int,
	height:            c.int,
	frame_rate:        f64,
	start_frame:       i64,
	end_frame:         i64,
	resolution_locked: bool,
}

// project_name_owned tracks whether project.name is a session-heap clone
// (loaded from a file) rather than the default literal "Untitled Project".
// The literal must never be deleted; a replaced loaded name must be.
project_name_owned: bool

// project_to_file copies the live Project into its serializable shape.
project_to_file :: proc() -> Project_File {
	return Project_File {
		name              = project.name,
		width             = project.width,
		height            = project.height,
		frame_rate        = project.frame_rate,
		start_frame       = project.start_frame,
		end_frame         = project.end_frame,
		resolution_locked = project.resolution_locked,
	}
}

// project_set_name replaces project.name with a clone of `name`; frees any
// previous loaded name so repeated opens don't leak.
project_set_name :: proc(name: string) {
	if project_name_owned {
		delete(project.name)
	}
	project.name = strings.clone(name)
	project_name_owned = true
}

// project_file_save writes the current project snapshot to `path` as CBOR.
// Returns a notice text on failure ("" = success).
project_file_save :: proc(path: string) -> string {
	pf := project_to_file()
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

// project_file_open reads `path` as CBOR and applies the project metadata to
// the live Project. Returns a notice text on failure ("" = success).
project_file_open :: proc(path: string) -> string {
	bytes, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return fmt.aprintf("failed to read '%s': %v", path, rerr)
	}
	defer delete(bytes)

	pf: Project_File
	uerr := cbor.unmarshal_from_bytes(bytes, &pf)
	if uerr != nil {
		return fmt.aprintf("'%s' is not a valid project file: %v", path, uerr)
	}

	if pf.width > 0 && pf.height > 0 {
		project.width = pf.width
		project.height = pf.height
	}
	project.frame_rate = pf.frame_rate
	project.start_frame = pf.start_frame
	project.end_frame = pf.end_frame
	project.resolution_locked = pf.resolution_locked
	project_set_name(pf.name)
	// project_set_name clones pf.name into the session-bound project.name;
	// the unmarshal-owned copy can go now.
	delete(pf.name)
	return ""
}

// project_path_is_project reports whether a path names a project file (by its
// .vyproj extension). The finder and :open route non-project paths to media;
// this is the dispatch test.
project_path_is_project :: proc(path: string) -> bool {
	return strings.has_suffix(path, ".vyproj")
}