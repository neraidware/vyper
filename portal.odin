package main

import "core:c"
import "core:fmt"

GError :: struct {
	domain: u32,
	code: c.int,
	message: cstring,
}
GDBusConnection :: struct {}
GMainLoop :: struct {}
GVariant :: struct {}
GVariantType :: struct {}

GDBusSignalCallback :: proc "c" (
	connection: ^GDBusConnection,
	sender_name, object_path, interface_name, signal_name: cstring,
	parameters: ^GVariant,
	user_data: rawptr,
)

foreign import glib "system:glib-2.0"
foreign import gio "system:gio-2.0"

foreign glib {
	g_variant_parse :: proc(
	_type: ^GVariantType,
	text, limit: cstring,
	endptr: ^^c.char,
	error: ^^GError,
	) -> ^GVariant ---
	g_variant_unref :: proc(value: ^GVariant) ---
	g_variant_ref :: proc(value: ^GVariant) -> ^GVariant ---
	g_error_free :: proc(error: ^GError) ---
	g_variant_get_child_value :: proc(value: ^GVariant, index: c.size_t) -> ^GVariant ---
	g_variant_n_children :: proc(value: ^GVariant) -> c.size_t ---
	g_variant_get_string :: proc(value: ^GVariant, length: ^c.size_t) -> cstring ---
	g_variant_get_uint32 :: proc(value: ^GVariant) -> u32 ---
	g_variant_lookup_value :: proc(value: ^GVariant, key: cstring, expected_type: ^GVariantType) -> ^GVariant ---
	g_filename_from_uri :: proc(uri, hostname: cstring, error: ^^GError) -> cstring ---
	g_main_loop_new :: proc(ctx: rawptr, is_running: bool) -> ^GMainLoop ---
	g_main_loop_run :: proc(loop: ^GMainLoop) ---
	g_main_loop_quit :: proc(loop: ^GMainLoop) ---
	g_main_loop_unref :: proc(loop: ^GMainLoop) ---
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
	g_dbus_connection_signal_unsubscribe :: proc(connection: ^GDBusConnection, subscription_id: u32) ---
}

portal_loop: ^GMainLoop
portal_response_data: ^GVariant

portal_response :: proc "c" (
	connection: ^GDBusConnection,
	sender_name, object_path, interface_name, signal_name: cstring,
	parameters: ^GVariant,
	user_data: rawptr,
) {
	portal_response_data = g_variant_ref(parameters)
	g_main_loop_quit(portal_loop)
}

portal_open_file_picker :: proc() -> cstring {
	portal_response_data = nil
	connection := g_bus_get_sync(2, nil, nil) // G_BUS_TYPE_SESSION
	if connection == nil {
		fmt.println("Could not connect to session bus")
		return nil
	}

	parameters := g_variant_parse(
		nil,
		"('', 'Open media file', {" +
			"'handle_token': <'nered_open'>, " +
			"'filters': <[" +
				"('Video', [(uint32 0, '*.mp4'), (uint32 0, '*.m4v'), (uint32 0, '*.mov'), (uint32 0, '*.mkv'), (uint32 0, '*.webm'), (uint32 0, '*.avi'), (uint32 0, '*.mpeg'), (uint32 0, '*.mpg'), (uint32 0, '*.ts'), (uint32 0, '*.m2ts'), (uint32 0, '*.flv'), (uint32 0, '*.wmv'), (uint32 0, '*.3gp')]), " +
				"('Audio', [(uint32 0, '*.mp3'), (uint32 0, '*.wav'), (uint32 0, '*.flac'), (uint32 0, '*.ogg'), (uint32 0, '*.opus'), (uint32 0, '*.m4a'), (uint32 0, '*.aac')]), " +
				"('Images', [(uint32 0, '*.png'), (uint32 0, '*.jpg'), (uint32 0, '*.jpeg'), (uint32 0, '*.webp'), (uint32 0, '*.gif'), (uint32 0, '*.bmp'), (uint32 0, '*.tiff')])" +
			"]>})",
		nil,
		nil,
		nil,
	)
	if parameters == nil {
		fmt.println("Could not create portal request parameters")
		return nil
	}

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
	portal_loop = g_main_loop_new(nil, false)
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
	g_main_loop_run(portal_loop)
	g_dbus_connection_signal_unsubscribe(connection, subscription)
	g_main_loop_unref(portal_loop)
	g_variant_unref(request)
	g_variant_unref(reply)
	if portal_response_data == nil {
		return nil
	}
	// The Response signal parameters are a tuple "(u a{sv})":
	//   child 0 = response code (0 = success, 1 = user cancelled, 2 = error)
	//   child 1 = results dict (a{sv}).
	// If the user closes the dialog without picking a file, the code is non-zero
	// and/or the results dict may be EMPTY. On cancel/error we must return nil
	// immediately without touching the empty results — parsing an empty (or
	// NULL) results dict is exactly what segfaulted g_variant_get_string.
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
