// Linux-only xdg-desktop-portal file picker. Excluded from non-Linux builds;
// Windows gets `portal_windows.odin` (`win32_open_file_picker`), dispatched by
// `media.open_file_picker`.
#+build !windows
package main

import "core:c"
import "core:fmt"
import "core:time"

GError :: struct {
	domain: u32,
	code: c.int,
	message: cstring,
}
GDBusConnection :: struct {}
GMainLoop :: struct {}
GVariant :: struct {}
GVariantType :: struct {}
GVariantBuilder :: struct {}

GDBusSignalCallback :: proc "c" (
	connection: ^GDBusConnection,
	sender_name, object_path, interface_name, signal_name: cstring,
	parameters: ^GVariant,
	user_data: rawptr,
)

foreign import glib "system:glib-2.0"
foreign import gio "system:gio-2.0"

foreign glib {
	g_variant_unref :: proc(value: ^GVariant) ---
	g_variant_ref :: proc(value: ^GVariant) -> ^GVariant ---
	g_error_free :: proc(error: ^GError) ---
	g_variant_new_string :: proc(s: cstring) -> ^GVariant ---
	g_variant_new_uint32 :: proc(v: u32) -> ^GVariant ---
	g_variant_new_variant :: proc(value: ^GVariant) -> ^GVariant ---
	g_variant_new_tuple :: proc(children: rawptr, n_children: c.size_t) -> ^GVariant ---
	g_variant_new_dict_entry :: proc(key: ^GVariant, value: ^GVariant) -> ^GVariant ---
	g_variant_type_new :: proc(type_string: cstring) -> ^GVariantType ---
	g_variant_type_free :: proc(type: ^GVariantType) ---
	g_variant_builder_new :: proc(type: ^GVariantType) -> ^GVariantBuilder ---
	g_variant_builder_unref :: proc(builder: ^GVariantBuilder) ---
	g_variant_builder_end :: proc(builder: ^GVariantBuilder) -> ^GVariant ---
	g_variant_builder_add_value :: proc(builder: ^GVariantBuilder, value: ^GVariant) ---
	g_variant_get_child_value :: proc(value: ^GVariant, index: c.size_t) -> ^GVariant ---
	g_variant_n_children :: proc(value: ^GVariant) -> c.size_t ---
	g_variant_get_string :: proc(value: ^GVariant, length: ^c.size_t) -> cstring ---
	g_variant_get_uint32 :: proc(value: ^GVariant) -> u32 ---
	g_variant_lookup_value :: proc(value: ^GVariant, key: cstring, expected_type: ^GVariantType) -> ^GVariant ---
	g_filename_from_uri :: proc(uri, hostname: cstring, error: ^^GError) -> cstring ---
	g_main_context_iteration :: proc(ctx: rawptr, may_block: bool) -> bool ---
}

foreign gio {
	g_bus_get_sync :: proc(bus_type: c.int, cancellable: rawptr, error: ^^GError) -> ^GDBusConnection ---
	g_dbus_connection_call_sync :: proc(
	connection: ^GDBusConnection,
	bus_name, object_path, interface_name, method_name: cstring,
	parameters: ^GVariant,
	 reply_type: ^GVariantType,
	flags: c.int,
	timeout_msec: c.int,
	cancellable: rawptr,
	error: ^^GError,
	) -> ^GVariant ---
	g_dbus_connection_signal_subscribe :: proc(
	connection: ^GDBusConnection,
	sender, interface_name, member, object_path, arg0: cstring,
	flags: c.int,
	callback: GDBusSignalCallback,
	user_data: rawptr,
	user_data_free_func: rawptr,
	) -> u32 ---
}

// The Response signal subscription is created per dialog with an exact
// request-path match, and (deliberately) never torn down. The old
// per-dialog subscribe + nested GMainLoop + unsubscribe cycle finalized
// gio's internal signal listener twice (g_ref_count_dec saw rc=-1 inside
// g_dbus_connection_signal_unsubscribe), crashing with "GLib CRITICAL:
// g_atomic_ref_count_dec: old_value > 0" on dialog close. Instead dialogs
// wait by polling the process-default main context until the Response
// arrives, and each subscription is left to live out the session (a small,
// bounded per-dialog leak) rather than risk the double-finalize. Standard
// gio match-object clustering keeps a nil match from a flood of unrelated
// portal signals: only one dialog is pending at a time here.
portal_dialog_pending: bool
portal_response_data: ^GVariant

portal_response :: proc "c" (
	connection: ^GDBusConnection,
	sender_name, object_path, interface_name, signal_name: cstring,
	parameters: ^GVariant,
	user_data: rawptr,
) {
	if !portal_dialog_pending {
		// A stale Response from a previous dialog: keep the current wait
		// pending, ignore the emission entirely (no ref, no leak).
		return
	}
	portal_response_data = g_variant_ref(parameters)
	portal_dialog_pending = false
}

// Portal_Filter is a FileChooser filter: a display name plus its glob patterns.
// The portal wire type for `filters` is a(sa(us)) — a list of (name, patterns)
// structs where each pattern is (uint32 0, '*.ext'). Built with g_variant_builder:
// GLib's text-format parser cannot express a a(sa(us)) value (a single-element
// array of tuples is not type-inferable, "unable to find a common type"), which
// previously made every portal dialog fail at g_variant_parse.
Portal_Filter :: struct {
	name:     string,
	patterns: []string,
}

portal_filter_media := Portal_Filter{
	name = "Media files",
	patterns = {
		"*.mp4", "*.m4v", "*.mov", "*.mkv", "*.webm", "*.avi", "*.mpeg", "*.mpg",
		"*.ts", "*.m2ts", "*.flv", "*.wmv", "*.3gp", "*.mp3", "*.wav", "*.flac",
		"*.ogg", "*.opus", "*.m4a", "*.aac", "*.png", "*.jpg", "*.jpeg", "*.webp",
		"*.gif", "*.bmp", "*.tiff", "*.srt",
	},
}

portal_filter_srt := Portal_Filter{name = "Subtitle files", patterns = {"*.srt"}}

// portal_build_filters builds the `filters` a(sa(us)) value for one filter.
portal_build_filters :: proc(f: Portal_Filter) -> ^GVariant {
	filters_type := g_variant_type_new("a(sa(us))")
	defer g_variant_type_free(filters_type)
	filters := g_variant_builder_new(filters_type)

	patterns_type := g_variant_type_new("a(us)")
	pattern_type := g_variant_type_new("(us)")
	patterns := g_variant_builder_new(patterns_type)
	for p in f.patterns {
		entry := g_variant_builder_new(pattern_type)
		g_variant_builder_add_value(entry, g_variant_new_uint32(0))
		g_variant_builder_add_value(entry, g_variant_new_string(cstring(raw_data(p))))
		g_variant_builder_add_value(patterns, g_variant_builder_end(entry))
		g_variant_builder_unref(entry)
	}
	value := g_variant_builder_end(patterns)
	g_variant_builder_unref(patterns)

	filter_type := g_variant_type_new("(sa(us))")
	filter := g_variant_builder_new(filter_type)
	g_variant_builder_add_value(filter, g_variant_new_string(cstring(raw_data(f.name))))
	g_variant_builder_add_value(filter, value)
	// add_value consumed `value`'s reference; `end` hands back a fresh one.
	g_variant_builder_add_value(filters, g_variant_builder_end(filter))
	g_variant_builder_unref(filter)

	result := g_variant_builder_end(filters)
	g_variant_builder_unref(filters)
	g_variant_type_free(patterns_type)
	g_variant_type_free(pattern_type)
	g_variant_type_free(filter_type)
	return result
}

// portal_build_open_params builds the OpenFile `(sa{sv})` parameters variant.
portal_build_open_params :: proc(title: string, f: Portal_Filter) -> ^GVariant {
	dict_type := g_variant_type_new("a{sv}")
	dict := g_variant_builder_new(dict_type)

	// Each option is a {sv} dict entry. g_variant_new_* constructors and
	// g_variant_builder_add_value CONSUME their children's references, so no
	// intermediate unrefs.
	add_option :: proc(dict: ^GVariantBuilder, key: string, val: ^GVariant) {
		entry := g_variant_new_dict_entry(g_variant_new_string(cstring(raw_data(key))), g_variant_new_variant(val))
		g_variant_builder_add_value(dict, entry)
	}

	add_option(dict, "handle_token", g_variant_new_string("vyper_open"))
	add_option(dict, "filters", portal_build_filters(f))
	options := g_variant_builder_end(dict)
	g_variant_builder_unref(dict)
	g_variant_type_free(dict_type)

	// The portal's FileChooser methods take (parent_window, title, options) as
	// a three-part tuple `(ssa{sv})`. g_variant_new_tuple consumes the refs of
	// `parent`, `title`, and `options`.
	parent := g_variant_new_string("")
	title_v := g_variant_new_string(cstring(raw_data(title)))
	params := g_variant_new_tuple(raw_data([]^GVariant{parent, title_v, options}), 3)
	return params
}

// portal_open_picker runs the XDG portal OpenFile dialog with the given title
// and filter, returning the picked path as a cstring into glib-owned memory
// (kept alive for the program's lifetime) or nil on cancel/error. Shared by the
// media and subtitle pickers; the dialog is modal and blocks as the portal's
// synchronous GDBus plumbing does.
portal_open_picker :: proc(title: string, filter: Portal_Filter) -> cstring {
	portal_response_data = nil
	connection := g_bus_get_sync(2, nil, nil) // G_BUS_TYPE_SESSION
	if connection == nil {
		fmt.println("Could not connect to session bus")
		return nil
	}

	parameters := portal_build_open_params(title, filter)
	error: ^GError
	reply := g_dbus_connection_call_sync(
		connection,
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.FileChooser",
		"OpenFile",
		parameters,
		nil,
		0,
		-1,
		nil,
		&error,
	)
	g_variant_unref(parameters)
	if reply == nil {
		if error != nil {
			fmt.println("Portal request failed:", string(error.message))
			g_error_free(error)
		} else {
			fmt.println("Portal request failed")
		}
		return nil
	}

	// The OpenFile reply is "(o)" — one child: the request object path. If the
	// D-Bus service returns an error, `reply` may hold an error variant with
	// zero children; guard it or g_variant_get_string(NULL) crashes.
	request := g_variant_get_child_value(reply, 0)
	if request == nil || g_variant_n_children(reply) < 1 {
		g_variant_unref(reply)
		return nil
	}
	request_path := g_variant_get_string(request, nil)
	path := portal_wait_response_path(connection, request_path)
	g_variant_unref(request)
	g_variant_unref(reply)
	return path
}

// portal_open_file_picker opens the media-file dialog (import entry point).
portal_open_file_picker :: proc() -> cstring {
	return portal_open_picker("Open media file", portal_filter_media)
}

// portal_open_srt_picker opens a subtitle (.srt)-only dialog.
portal_open_srt_picker :: proc() -> cstring {
	return portal_open_picker("Select subtitle file", portal_filter_srt)
}

// portal_wait_response_path runs the portal dialog to completion (blocking the
// calling thread until the request resolves) and returns the first picked file's
// local path as a cstring into glib-owned memory (kept alive for the program's
// lifetime, matching the win32 picker's persistent buffer). Returns nil on any
// error, user cancel, or empty pick.
//
// The Request.Response signal parameters are a tuple "(u a{sv})":
//   child 0 = response code (0 = success, 1 = user cancelled, 2 = error)
//   child 1 = results dict (a{sv}).
// If the user closes the dialog without picking a file the code is non-zero
// and/or the results dict is EMPTY. On cancel/error we must return nil
// immediately without touching the empty results — parsing an empty (or NULL)
// results dict is exactly what segfaulted g_variant_get_string.
portal_wait_response_path :: proc(connection: ^GDBusConnection, request_path: cstring) -> cstring {
	subscription := g_dbus_connection_signal_subscribe(
		connection,
		"org.freedesktop.portal.Desktop",
		"org.freedesktop.portal.Request",
		"Response",
		request_path,
		nil,
		0,
		portal_response,
		nil,
		nil,
	)
	if subscription == 0 {
		fmt.println("Portal: could not subscribe to Request/Response")
		return nil
	}
	portal_dialog_pending = true
	// Pump the default main context until the portal emits Response. The old
	// nested g_main_loop_run + per-dialog unsubscribe double-finalized gio's
	// internal listener; iterating the existing default context (and leaving
	// the subscription alive) has nothing to tear down.
	started := time.now()
	for portal_dialog_pending {
		g_main_context_iteration(nil, false)
		if time.since(started) > 5 * time.Minute {
			fmt.println("Portal: dialog timed out")
			portal_dialog_pending = false
			portal_response_data = nil
			return nil
		}
		time.sleep(2 * time.Millisecond)
	}
	if portal_response_data == nil {
		return nil
	}
	if g_variant_n_children(portal_response_data) < 2 {
		g_variant_unref(portal_response_data)
		return nil
	}
	code_child := g_variant_get_child_value(portal_response_data, 0)
	response_code := g_variant_get_uint32(code_child)
	g_variant_unref(code_child)
	if response_code != 0 {
		g_variant_unref(portal_response_data)
		return nil
	}
	results := g_variant_get_child_value(portal_response_data, 1)
	if results == nil {
		g_variant_unref(portal_response_data)
		return nil
	}
	uris := g_variant_lookup_value(results, "uris", nil)
	g_variant_unref(results)
	if uris == nil {
		g_variant_unref(portal_response_data)
		return nil
	}
	// uris is "as" (array of strings); on an empty array child 0 is NULL.
	first_uri := g_variant_get_child_value(uris, 0)
	if first_uri == nil {
		g_variant_unref(uris)
		g_variant_unref(portal_response_data)
		return nil
	}
	uri := g_variant_get_string(first_uri, nil)
	path := g_filename_from_uri(uri, nil, nil)
	g_variant_unref(first_uri)
	g_variant_unref(uris)
	g_variant_unref(portal_response_data)
	return path
}

// portal_save_file_picker opens the portal SaveFile dialog for the render output
// path. Same request/Response plumbing as open, but through the SaveFile method
// and seeded with the current default output name so the dialog opens on it.
portal_save_file_picker :: proc() -> cstring {
	portal_response_data = nil
	connection := g_bus_get_sync(2, nil, nil) // G_BUS_TYPE_SESSION
	if connection == nil {
		fmt.println("Could not connect to session bus")
		return nil
	}

	default_name := "out.mp4"
	if render_out_path_len > 0 {
		default_name = path_basename(cstring(&render_out_path_buf[0]))
	}
	dict_type := g_variant_type_new("a{sv}")
	dict := g_variant_builder_new(dict_type)

	add_option :: proc(dict: ^GVariantBuilder, key, value: cstring) {
		entry := g_variant_new_dict_entry(g_variant_new_string(key), g_variant_new_variant(g_variant_new_string(value)))
		g_variant_builder_add_value(dict, entry)
	}

	add_option(dict, "handle_token", "vyper_save")
	add_option(dict, "current_name", cstring(raw_data(default_name)))
	// Open the dialog on the folder that holds the current output path (for
	// the startup default, ~/Videos) instead of wherever the portal last was.
	{
		out := string(render_out_path_buf[:render_out_path_len])
		dir_end := 0
		for i := len(out) - 1; i >= 0; i -= 1 {
			if out[i] == '/' {
				dir_end = i
				break
			}
		}
		if dir_end > 0 {
			uri_buf: [1024]u8
			uri := fmt.bprintf(uri_buf[:], "file://%s", out[:dir_end])
			uri_buf[len(uri)] = 0
			add_option(dict, "current_folder", cstring(raw_data(uri)))
		}
	}
	{ // filters (a(sa(us)) value, not a plain string)
		filter := Portal_Filter{name = "MP4 video", patterns = {"*.mp4"}}
		entry := g_variant_new_dict_entry(g_variant_new_string("filters"), g_variant_new_variant(portal_build_filters(filter)))
		g_variant_builder_add_value(dict, entry)
	}
	options := g_variant_builder_end(dict)
	g_variant_builder_unref(dict)
	g_variant_type_free(dict_type)

	// Same (parent_window, title, options) `(ssa{sv})` shape as OpenFile.
	parent := g_variant_new_string("")
	title_v := g_variant_new_string("Save render output")
	parameters := g_variant_new_tuple(raw_data([]^GVariant{parent, title_v, options}), 3)

	error: ^GError
	reply := g_dbus_connection_call_sync(
		connection,
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.FileChooser",
		"SaveFile",
		parameters,
		nil,
		0,
		-1,
		nil,
		&error,
	)
	g_variant_unref(parameters)
	if reply == nil {
		if error != nil {
			fmt.println("Portal save request failed:", string(error.message))
			g_error_free(error)
		} else {
			fmt.println("Portal save request failed")
		}
		return nil
	}

	request := g_variant_get_child_value(reply, 0)
	if request == nil || g_variant_n_children(reply) < 1 {
		g_variant_unref(reply)
		return nil
	}
	request_path := g_variant_get_string(request, nil)
	path := portal_wait_response_path(connection, request_path)
	g_variant_unref(request)
	g_variant_unref(reply)
	return path
}
