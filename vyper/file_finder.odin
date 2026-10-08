package vyper

import "core:sys/windows"
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"

// ---------------------------------------------------------------------------
// In-app fuzzy file finder (fzf/skim-flavored, not telescope-style): a modal
// popup listing the current directory's entries with a filter field on top.
// Enter descends into a directory (clearing the filter) or opens the selected
// file through the caller's commit proc; Esc/Esc-cancel closes. Replaces the
// OS-native open/import dialogs (`:open` bare, Open File and Bin Import
// buttons) so every platform shares one file-management UI.
//
// The field's meaning is the one thing that differs per mode: Open/ImportBin
// type a fuzzy filter that narrows the rows, while Save types a file NAME and
// leaves every row visible for navigation (see finder_refresh). Save commits
// that name against the browsed directory, not the highlighted row.
//
// Memory model: the listing is session-owned (freed by finder_close/reset);
// each entry holds a cloned basename + fullpath. `cwd` is a cloned absolute
// path of the directory being browsed. Filter text lives in the shared `ti`
// field (TI_FINDER), so filtering reuses the caret/clipboard/IME machinery.
// ---------------------------------------------------------------------------

FINDER_MAX_ROWS :: 16    // visible rows under the filter (popup height cap)
FINDER_ENTRIES_MAX :: 20000 // safety cap: stop scanning past this many entries
FINDER_QUERY_MAX :: 127  // filter bytes considered for matching/draw

Finder_Commit_Mode :: enum { Open, ImportBin, Save }

Finder_Kind :: enum { Folder, Video, Audio, Image, Subtitle, File }

Finder_Entry :: struct {
	name:     string, // basename (session-owned clone)
	fullpath: string, // absolute path (session-owned clone)
	is_dir:   bool,   // directory (incl. symlink-to-dir; os.is_dir follows links)
	is_symlink: bool,
	kind:     Finder_Kind,
}

File_Finder :: struct {
	active: bool,
	cwd:    string, // absolute dir being browsed (session-owned; "" when inactive)
	mode:   Finder_Commit_Mode,
	entries:   [dynamic]Finder_Entry, // current dir listing, dirs-first/alphabetical
	filtered:  [dynamic]int,          // indices into entries passing the filter
	sel:       int,                   // index into filtered
	scroll:    int,                   // first visible row window
	query_buf: [FINDER_QUERY_MAX + 1]u8, // refresh-compare scratch for the filter
	query_len: int,
	// filtered_valid records that `filtered` matches the CURRENT entries and
	// query. `filtered` is derived from both, so keying the refresh memo on the
	// query alone went stale whenever finder_relist rebuilt the entries under an
	// unchanged query — which left the listing blank until the user typed
	// something that happened to change the query.
	filtered_valid: bool,
}
file_finder: File_Finder

// FINDER_EXT_MAX bounds the extension this proc lowercases. Every extension it
// matches is far shorter; a longer one matches nothing and falls to .File
// anyway, so it is left alone rather than truncated into a wrong answer.
FINDER_EXT_MAX :: 16

// finder_kind_of classifies a file by extension into an icon kind. Unrecognized
// extensions (and extensionless files) fall to .File — a generic document.
finder_kind_of :: proc(name: string) -> Finder_Kind {
	ext := ""
	if dot := strings.last_index(name, "."); dot >= 0 && dot + 1 < len(name) {
		// Lowercased into a stack buffer, not with strings.to_lower: this runs
		// once per listed entry on every relist, and to_lower heap-allocates a
		// string that was then dropped on the floor.
		raw := name[dot + 1:]
		if len(raw) <= FINDER_EXT_MAX {
			buf: [FINDER_EXT_MAX]u8
			for i in 0 ..< len(raw) {
				b := raw[i]
				buf[i] = (b >= 'A' && b <= 'Z') ? b + ('a' - 'A') : b
			}
			ext = string(buf[:len(raw)])
		}
	}
	switch ext {
	case "mp4", "mov", "mkv", "webm", "avi", "m4v", "ts", "mts", "m2ts", "mpg", "mpeg":
		return .Video
	case "mp3", "wav", "flac", "aac", "ogg", "oga", "opus", "m4a", "wma", "ac3":
		return .Audio
	case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "svg":
		return .Image
	case "srt", "vtt", "ass", "ssa", "sub":
		return .Subtitle
	case:
		return .File
	}
}

// finder_clear drops the session-owned listing and resets browse state.
finder_clear :: proc() {
	for e in file_finder.entries {
		delete(e.name)
		delete(e.fullpath)
	}
	clear(&file_finder.entries)
	clear(&file_finder.filtered)
	file_finder.filtered_valid = false
	delete(file_finder.cwd)
	file_finder.cwd = ""
	file_finder.sel = 0
	file_finder.scroll = 0
	file_finder.query_len = 0
}

// finder_relist scans the current cwd into entries: synthetic parent ".."
// pinned at top when not at the fs root, then every non-hidden entry
// directory-grouped alphabetical (dirs first, then files), following symlinks
// to directories (os.is_dir). Non-fatal: a failed read keeps the old listing.
finder_relist :: proc() {
	if !file_finder.active || len(file_finder.cwd) == 0 {
		return
	}
	// Keep one session-owned string per parent path; built from cwd's dir.
	parent := path_dir(file_finder.cwd)
	for e in file_finder.entries {
		delete(e.name)
		delete(e.fullpath)
	}
	clear(&file_finder.entries)
	clear(&file_finder.filtered)
	// The listing just changed, so the filter output is stale regardless of the
	// query text. finder_refresh rebuilds it on the next draw.
	file_finder.filtered_valid = false
	file_finder.sel = 0
	file_finder.scroll = 0

	if parent != file_finder.cwd {
		append(
			&file_finder.entries,
			Finder_Entry {
				name = strings.clone(".."),
				fullpath = strings.clone(parent),
				is_dir = true,
				kind = .Folder,
			},
		)
	}
	delete(parent)
	infos, err := os.read_all_directory_by_path(file_finder.cwd, context.temp_allocator)
	if err != nil {
		// Keep the parent row only; a notice explains the failed read.
		return
	}
	for info in infos {
		if len(file_finder.entries) >= FINDER_ENTRIES_MAX {
			break
		}
		if len(info.name) > 0 && info.name[0] == '.' {
			continue // hidden
		}
		is_dir := os.is_dir(info.fullpath) // follows symlinks
		append(
			&file_finder.entries,
			Finder_Entry {
				name = strings.clone(info.name),
				fullpath = strings.clone(info.fullpath),
				is_dir = is_dir,
				is_symlink = info.type == .Symlink,
				kind = is_dir ? .Folder : finder_kind_of(info.name),
			},
		)
	}
	// Dirs first, alphabetical within each bucket (".." rides in the dir bucket
	// but its "." prefix sorts it first naturally).
	sort.quick_sort_proc(file_finder.entries[:], proc(a, b: Finder_Entry) -> int {
		if a.is_dir != b.is_dir {
			return 1 if b.is_dir else -1
		}
		return strings.compare(a.name, b.name)
	})
}

// finder_refresh rebuilds the filtered index list when EITHER input changed
// since the last build: the query text, or the entries listing (a descend, go
// up, or a fresh open — see filtered_valid). Both are needed because the output
// is a function of both; keying on the query alone left a freshly opened or
// freshly descended listing blank until the user typed something. Selection
// clamps to the new list and the scroll window follows the selected row.
finder_refresh :: proc() {
	query := text_input_string()
	query_unchanged :=
		len(query) == file_finder.query_len &&
		string(file_finder.query_buf[:file_finder.query_len]) == query
	if file_finder.filtered_valid && query_unchanged {
		return
	}
	qn := min(len(query), FINDER_QUERY_MAX)
	copy(file_finder.query_buf[:qn], query[:qn])
	file_finder.query_len = qn
	clear(&file_finder.filtered)
	// Save mode types a file NAME, not a query: the field must not narrow the
	// listing, or the rows used to navigate to a directory would vanish as
	// soon as the first character is typed.
	match_all := file_finder.mode == .Save
	for i in 0 ..< len(file_finder.entries) {
		if match_all ||
		   qn == 0 ||
		   cmdline_fuzzy_score(query[:qn], file_finder.entries[i].name) > 0 {
			append(&file_finder.filtered, i)
		}
	}
	if len(file_finder.filtered) == 0 {
		file_finder.sel = 0
	} else {
		file_finder.sel = clamp(file_finder.sel, 0, len(file_finder.filtered) - 1)
	}
	file_finder.filtered_valid = true
	finder_clamp_scroll()
}

// finder_clamp_scroll keeps the selected row inside the visible window.
finder_clamp_scroll :: proc() {
	if file_finder.sel < file_finder.scroll {
		file_finder.scroll = file_finder.sel
	}
	if file_finder.sel >= file_finder.scroll + FINDER_MAX_ROWS {
		file_finder.scroll = file_finder.sel - FINDER_MAX_ROWS + 1
	}
	c := max(0, len(file_finder.filtered) - FINDER_MAX_ROWS)
	file_finder.scroll = clamp(file_finder.scroll, 0, c)
}

// finder_navigate moves the highlight by delta rows, wrapping.
finder_navigate :: proc(delta: int) {
	n := len(file_finder.filtered)
	if n == 0 {
		return
	}
	file_finder.sel = (file_finder.sel + delta + n * 1000) % n
	finder_clamp_scroll()
}

// path_dir returns cwd's parent directory as a session-owned heap string
// (caller deletes). Computes the last separator bucket; a root cwd returns a
// clone of itself so ".." disappears.
path_dir :: proc(cwd: string) -> string {
	end := len(cwd)
	for end > 0 && (cwd[end - 1] == '/' || cwd[end - 1] == '\\') {
		end -= 1
	}
	for end > 0 && cwd[end - 1] != '/' && cwd[end - 1] != '\\' {
		end -= 1
	}
	if end <= 1 {
		return strings.clone(cwd)
	}
	return strings.clone(cwd[:end])
}

// finder_selected_entries returns the entries vs the current filter/selection.
finder_selected :: proc() -> (^Finder_Entry, bool) {
	if len(file_finder.filtered) == 0 {
		return nil, false
	}
	idx := file_finder.filtered[clamp(file_finder.sel, 0, len(file_finder.filtered) - 1)]
	return &file_finder.entries[idx], true
}

// finder_enter commits the selected row: a directory descends (relist the
// target and clear the filter), a file invokes the caller's commit proc.
//
// Save mode splits the two: a typed name IS the commit, so Enter saves it and
// the highlighted row is ignored. An EMPTY field keeps the row semantics, which
// is what keeps both actions on one key — otherwise a pre-filled suggestion
// would make the first Enter a save and navigating to another directory
// impossible (or, the other way, Enter on ".." would navigate when the user
// meant to save).
finder_enter :: proc() {
	if !file_finder.active {
		return
	}
	if file_finder.mode == .Save &&
	   len(strings.trim_space(text_input_string())) > 0 {
		finder_save_typed_name()
		return
	}
	entry, ok := finder_selected()
	if !ok {
		finder_enter_typed_path()
		return
	}
	if entry.is_dir {
		finder_descend(entry.fullpath)
		return
	}
	finder_commit(entry^)
}

// finder_descend re-bases the finder on `dir` (absolute) and clears the filter
// so the new dir lists fresh.
finder_descend :: proc(dir: string) {
	if !file_finder.active {
		return
	}
	delete(file_finder.cwd)
	file_finder.cwd = strings.clone(dir)
	text_input_set_buf("")
	finder_relist()
}

// finder_enter_typed_path lets Enter with a full typed path open it even when
// no filtered row matched (the list is a shortcut, the typed path is the real
// target). Directories descend; files commit. No-op otherwise.
finder_enter_typed_path :: proc() {
	path := strings.trim_space(text_input_string())
	if len(path) == 0 {
		return
	}
	if !os.exists(path) {
		return
	}
	if os.is_dir(path) {
		finder_descend(path)
	} else {
		// name is unused by finder_commit; fullpath must own its bytes (a slice
		// into ti.buf would dangle the moment the finder closes and frees it).
		entry := Finder_Entry {
			fullpath = strings.clone(path),
		}
		finder_commit(entry)
		delete(entry.fullpath)
	}
}

path_last_component :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[i + 1:]
		}
	}
	return path
}

// finder_go_up ascends one directory (via the ".." parent row).
finder_go_up :: proc() {
	if !file_finder.active || len(file_finder.cwd) == 0 {
		return
	}
	p := path_dir(file_finder.cwd)
	if p == file_finder.cwd {
		return
	}
	delete(file_finder.cwd)
	file_finder.cwd = p
	text_input_set_buf("")
	finder_relist()
}

// finder_commit applies the chosen file through the finder's commit mode:
// .Open opens like the Open File button (decodable media/subtitle only),
// .ImportBin imports into the media bin without touching the timeline,
// .Save writes the project to the name typed in the field.
finder_commit :: proc(entry: Finder_Entry) {
	switch file_finder.mode {
	case .Open:
		if project_path_is_project(entry.fullpath) {
			// A project file picked in the finder loads like `:open` would —
			// the finder is the bare :open's picker, so both paths must agree.
			// Neither one toasts on success (the app bar already names the open
			// project); a failed load still reports itself.
			if err := project_file_open(entry.fullpath); len(err) > 0 {
				defer delete(err)
				show_ui_notice(err, 4000)
			}
			finder_close()
			return
		}
		// open_file_at only reads `cpath` (the bin clones it), so the scratch
		// copy is freed as soon as the open returns.
		cpath := strings.clone_to_cstring(entry.fullpath)
		open_file_at(cpath)
		delete(cpath)
	case .ImportBin:
		// A project file is not media; importing it into the bin is a mistake.
		if project_path_is_project(entry.fullpath) {
			show_ui_notice("Project files can't be imported into the media bin", 4000)
			return
		}
		// import_media_to_bin/import_srt_to_bin store the path directly on the
		// asset, so the clone becomes bin-owned when a new asset is appended;
		// on a dedup no-op (path already in the bin) nothing stores it, so we
		// must free it. Cheap pre-check avoids guessing from the return id.
		already_in_bin := false
		for &a in media_bin.assets {
			if strings.compare(string(a.path), entry.fullpath) == 0 {
				already_in_bin = true
				break
			}
		}
		if already_in_bin {
			finder_close()
			return
		}
		cpath := strings.clone_to_cstring(entry.fullpath)
		if is_srt_pick(cpath) {
			import_srt_to_bin(cpath)
		} else {
			import_media_to_bin(cpath)
		}
	case .Save:
		// Reached only when Enter landed on a file row with an empty field
		// (a typed name is handled earlier, in finder_enter), so there is
		// nothing to save yet — say so instead of writing an unnamed file.
		finder_save_typed_name()
		return
	}
	finder_close()
}

// finder_default_save_name writes the name Save mode suggests — the project's
// name plus the project extension — into `buf` and returns the written span.
// It allocates nothing: the finder draws this as the field's placeholder every
// frame, and a per-frame heap allocation is never acceptable. Path separators
// become '_' because the field resolves against the browsed directory, and a
// separator in a project name would aim the save at a path the user never
// chose. An unnamed project still gets a usable name rather than a bare
// ".vyproj" (a hidden file). A name too long for `buf` is truncated, which is
// fine for a suggestion the user edits.
finder_default_save_name :: proc(buf: []u8) -> string {
	n := 0
	if len(project.name) == 0 {
		copy(buf, "project")
		n = len("project")
	} else {
		// Byte-wise so multi-byte UTF-8 passes through untouched; only the
		// ASCII separators are replaced.
		for i in 0 ..< len(project.name) {
			// Leave room for the extension.
			if n >= len(buf) - len(PROJECT_FILE_EXTENSION) {
				break
			}
			b := project.name[i]
			buf[n] = (b == '/' || b == '\\') ? '_' : b
			n += 1
		}
	}
	copy(buf[n:], PROJECT_FILE_EXTENSION)
	n += len(PROJECT_FILE_EXTENSION)
	return string(buf[:n])
}

// finder_save_typed_name saves the project under the name typed in the field,
// resolved against the directory being browsed. The finder stays open when the
// save fails so the name can be corrected and retried.
finder_save_typed_name :: proc() {
	name := strings.trim_space(text_input_string())
	if len(name) == 0 {
		show_ui_notice("Type a name to save the project", 3000)
		return
	}
	// `:open` routes on the .vyproj suffix, so a name typed with no extension
	// at all gets one. An explicit extension is left alone: the typed form of
	// `:save <path>` accepts any extension, and second-guessing a name the
	// user finished typing is worse than honoring it.
	suffix := ""
	if !strings.contains(path_last_component(name), ".") {
		suffix = PROJECT_FILE_EXTENSION
	}
	path := fmt.aprintf("%s/%s%s", file_finder.cwd, name, suffix)
	defer delete(path)
	if err := project_file_save(path); len(err) > 0 {
		defer delete(err)
		show_ui_notice(err, 4000)
		return
	}
	show_ui_noticef(3000, "Saved '%s'", path)
	finder_close()
}

// finder_open starts the finder from the process cwd in the given commit mode.
// The field always starts empty: Open/ImportBin use it as a filter, and Save
// uses it as a name it must not pre-fill (see finder_enter).
finder_open :: proc(mode: Finder_Commit_Mode) {
	if file_finder.active {
		finder_close()
	}

	cwd, err := os.user_home_dir(context.temp_allocator)

    if err != nil {
        cwd = os.get_working_directory(context.temp_allocator) or_else ""
    }

	file_finder.mode = mode
	file_finder.active = true
	file_finder.cwd = strings.clone(cwd)
	finder_relist()
	text_input_begin("", TI_FINDER, 0)
}

// finder_close dismisses the finder, dropping the session-owned listing and the
// filter field.
finder_close :: proc() {
	if !file_finder.active {
		return
	}
	file_finder.active = false
	finder_clear()
	text_input_cancel()
}
